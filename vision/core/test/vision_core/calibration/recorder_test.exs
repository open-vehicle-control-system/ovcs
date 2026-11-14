defmodule VisionCore.Calibration.RecorderTest do
  use ExUnit.Case, async: false

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.SensorMsgs.Msg.CameraInfo
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias VisionCore.Calibration.{Library, Recorder, Saved, Selection}
  alias VisionCore.Camera.Calibration, as: OwnCalibration
  alias VisionCore.Outputs
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Ros2.Services.SetCameraInfoServer

  @moduletag :tmp_dir

  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  @built_in Path.expand("../../support/calibration/identity_left.yaml", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    Repo.delete_all(Selection)
    Repo.delete_all(Saved)

    config = %VisionCore.Config{
      components: [
        {:camera,
         [
           name: :hq,
           driver: Camera,
           calibration: @built_in,
           calibration_store_dir: Path.join(tmp_dir, "store")
         ]}
      ]
    }

    %{config: config}
  end

  defp calibration(fx) do
    built_in = CameraCalibration.load!(@built_in)
    [_fx | rest] = built_in.camera_matrix
    %{built_in | camera_matrix: [fx | rest]}
  end

  # What a commit of `calibration(fx)` announces it stores, and how a session says it was made.
  defp figures(fx), do: [{"hq", calibration(fx)}]
  defp dashboard(samples), do: {:record, origin: "dashboard", samples: samples}

  defp start(config), do: start_supervised!({Recorder, config: config})

  # A change is cast to the recorder: its state is read once it has handled it.
  defp settled, do: :sys.get_state(Recorder)

  defp commit(config, fx) do
    :ok = OwnCalibration.commit(config, :hq, calibration(fx))
    settled()
  end

  test "selects nothing for a target on the firmware's calibration", %{config: config} do
    start(config)
    assert Library.list("hq") == []
    assert Library.selected("hq") == nil
  end

  test "keeps a calibration found in the store at start as imported, once", %{config: config} do
    :ok = OwnCalibration.commit(config, :hq, calibration(901.5))

    start(config)

    assert [%{origin: "imported", cameras: [%{name: "hq", fx: 901.5}]} = saved] =
             Library.list("hq")

    assert Library.selected("hq").id == saved.id

    stop_supervised!(Recorder)
    start(config)
    assert [%{id: id}] = Library.list("hq")
    assert id == saved.id
  end

  test "dates a calibration found in the store from its file, whatever the clock reads",
       %{config: config, tmp_dir: tmp_dir} do
    :ok = OwnCalibration.commit(config, :hq, calibration(901.5))
    File.touch!(Path.join([tmp_dir, "store", "camera_hq.yaml"]), {{2026, 11, 13}, {23, 28, 11}})

    start(config)

    assert [%{name: "2026-11-13 23:28 UTC", inserted_at: ~U[2026-11-13 23:28:11Z]}] =
             Library.list("hq")
  end

  test "keeps a committed calibration with the figures it was told to expect, and selects it", %{
    config: config
  } do
    start(config)

    Recorder.expect(
      "hq",
      figures(580.8),
      {:record,
       origin: "dashboard",
       board: %{columns: 8, rows: 6, square_m: 0.03},
       samples: 41,
       rms_px: %{"hq" => 0.2}}
    )

    commit(config, 580.8)

    assert [
             %{
               origin: "dashboard",
               samples: 41,
               board_columns: 8,
               cameras: [%{fx: 580.8, rms_px: 0.2}]
             } = saved
           ] =
             Library.list("hq")

    assert Library.selected("hq").id == saved.id

    # What was expected is used once.
    commit(config, 590.0)
    assert [%{origin: "imported", samples: nil}, _first] = Library.list("hq")
  end

  test "forgets what it was told to expect when the commit did not happen", %{config: config} do
    start(config)
    expectation = Recorder.expect("hq", figures(580.8), dashboard(41))
    :ok = Recorder.forget(expectation)

    commit(config, 580.8)
    assert [%{origin: "imported", samples: nil}] = Library.list("hq")
  end

  test "keeps each of two commits announced with its own figures, whichever is committed first",
       %{config: config} do
    start(config)
    Recorder.expect("hq", figures(600.0), dashboard(11))
    Recorder.expect("hq", figures(700.0), dashboard(22))

    commit(config, 700.0)
    commit(config, 600.0)

    assert [
             %{origin: "dashboard", samples: 11, cameras: [%{fx: 600.0}]},
             %{origin: "dashboard", samples: 22, cameras: [%{fx: 700.0}]}
           ] = Library.list("hq")
  end

  test "forgetting one commit leaves what another announced", %{config: config} do
    start(config)
    refused = Recorder.expect("hq", figures(600.0), dashboard(11))
    Recorder.expect("hq", figures(700.0), dashboard(22))

    :ok = Recorder.forget(refused)
    commit(config, 700.0)

    assert [%{origin: "dashboard", samples: 22}] = Library.list("hq")
  end

  test "keeps a change that is not the one announced as imported", %{config: config} do
    start(config)
    Recorder.expect("hq", figures(600.0), dashboard(11))

    commit(config, 650.0)

    assert [%{origin: "imported", cameras: [%{fx: 650.0}]}] = Library.list("hq")
  end

  test "drops what a process announced once it is gone without committing", %{config: config} do
    start(config)

    {announcer, monitor} =
      spawn_monitor(fn -> Recorder.expect("hq", figures(600.0), dashboard(11)) end)

    assert_receive {:DOWN, ^monitor, :process, ^announcer, :normal}
    settled()
    commit(config, 600.0)

    assert [%{origin: "imported", samples: nil}] = Library.list("hq")
  end

  test "keeps a commit with what its process announced when the process ends right after", %{
    config: config
  } do
    start(config)

    task =
      Task.async(fn ->
        Recorder.expect("hq", figures(600.0), dashboard(11))
        OwnCalibration.commit(config, :hq, calibration(600.0))
      end)

    assert Task.await(task) == :ok
    settled()

    assert [%{origin: "dashboard", samples: 11}] = Library.list("hq")
  end

  test "selects a calibration it already keeps instead of keeping it again", %{config: config} do
    start(config)
    commit(config, 580.8)
    commit(config, 590.0)
    [second, first] = Library.list("hq")
    assert Library.selected("hq").id == second.id

    commit(config, 580.8)
    assert length(Library.list("hq")) == 2
    assert Library.selected("hq").id == first.id
  end

  test "selects the calibration it was told to, among several holding the same figures", %{
    config: config
  } do
    start(config)
    {:ok, older} = Library.record("hq", [{"hq", calibration(580.8)}], origin: "dashboard")
    {:ok, _newer} = Library.record("hq", [{"hq", calibration(580.8)}], origin: "dashboard")

    Recorder.expect("hq", figures(580.8), {:select, older.id})
    commit(config, 580.8)

    assert Library.selected("hq").id == older.id
    assert length(Library.list("hq")) == 2
  end

  test "selects nothing for a stored calibration the library cannot keep, not the one before", %{
    config: config
  } do
    start(config)
    commit(config, 580.8)
    assert Library.selected("hq") != nil
    skewed = calibration(590.0)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok =
          OwnCalibration.commit(config, :hq, %{
            skewed
            | camera_matrix: List.replace_at(skewed.camera_matrix, 1, 0.5)
          })

        settled()
      end)

    assert Library.selected("hq") == nil
    assert log =~ "could not keep the calibration of hq"
    assert [%{cameras: [%{fx: 580.8}]}] = Library.list("hq")
  end

  test "selects nothing once the target is back on the firmware's calibration, and keeps the calibrations",
       %{config: config} do
    start(config)
    commit(config, 580.8)

    :ok = OwnCalibration.reset(config, :hq)
    settled()

    assert Library.selected("hq") == nil
    assert [%{cameras: [%{fx: 580.8}]}] = Library.list("hq")
  end

  for {flaw, left} <- [
        {"a matrix cut short", "camera_matrix:\n  data: [1.0, 2.0]\n"},
        {"an empty projection matrix",
         "camera_matrix:\n  data: [1, 0, 0, 0, 1, 0, 0, 0, 1]\nprojection_matrix:\n  data: []\n"},
        {"a value that is no number", "camera_matrix:\n  data: [.nan, 0, 0, 0, 1, 0, 0, 0, 1]\n"},
        {"nothing", ""}
      ] do
    test "starts and selects nothing for a pair whose stored left file holds #{flaw}", %{
      tmp_dir: tmp_dir
    } do
      assert_nothing_selected(tmp_dir, unquote(left))
    end
  end

  defp assert_nothing_selected(tmp_dir, left) do
    fixtures = Path.expand("../../support/calibration", __DIR__)
    store = Path.join(tmp_dir, "pair_store")
    File.mkdir_p!(store)
    File.cp!(Path.join(fixtures, "identity_right.yaml"), Path.join(store, "front_right.yaml"))
    File.write!(Path.join(store, "front_left.yaml"), left)

    config = %VisionCore.Config{
      components: [
        {:stereo,
         [
           driver: Camera,
           prefix: "front",
           calibration_store_dir: store,
           left: [calibration_path: Path.join(fixtures, "identity_left.yaml")],
           right: [calibration_path: Path.join(fixtures, "identity_right.yaml")]
         ]}
      ]
    }

    {{:ok, in_use}, _log} =
      ExUnit.CaptureLog.with_log(fn -> VisionCore.Calibration.in_use(config, "front") end)

    assert %{source: :stored, cameras: [%{calibration: nil}, %{calibration: %{}}]} = in_use

    ExUnit.CaptureLog.capture_log(fn -> start(config) end)
    assert Library.list("front") == []
    assert Library.selected("front") == nil
  end

  test "keeps a calibration committed through the camera's set_camera_info service, and tells it",
       %{config: config} do
    start(config)
    :ok = Outputs.subscribe(Recorder.changed_key("hq"))
    committed = calibration(733.25)

    server =
      start_supervised!(
        {SetCameraInfoServer,
         service_name: "hq/set_camera_info",
         commit: &OwnCalibration.commit(config, :hq, &1),
         register_service: fn _name, _module, _handler -> :ok end,
         respond: fn _name, _query, _payload -> :ok end}
      )

    camera_info = %CameraInfo{
      header: %Header{stamp: %Time{}, frame_id: "hq"},
      width: committed.width,
      height: committed.height,
      distortion_model: committed.distortion_model,
      d: committed.distortion_coefficients,
      k: committed.camera_matrix,
      r: committed.rectification_matrix,
      p: committed.projection_matrix
    }

    send(
      server,
      {:service_request,
       %{query: %Zenohex.Query{}, request_payload: CameraInfo.encode(camera_info)}}
    )

    :sys.get_state(server)
    settled()

    assert %{origin: "imported", cameras: [%{fx: 733.25}]} = Library.selected("hq")
    assert_received {:"$gen_cast", {:saved_calibrations_changed, "hq"}}
  end

  test "publishes each change of a target's library", %{config: config} do
    start(config)
    Outputs.subscribe(Recorder.changed_key("hq"))

    commit(config, 580.8)
    assert_receive {:"$gen_cast", {:saved_calibrations_changed, "hq"}}

    Recorder.changed("hq")
    assert_receive {:"$gen_cast", {:saved_calibrations_changed, "hq"}}
  end

  test "answers without a recorder running" do
    expectation = Recorder.expect("hq", figures(580.8), {:select, 1})

    assert is_reference(expectation)
    assert Recorder.forget(expectation) == :ok
  end
end
