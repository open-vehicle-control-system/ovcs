defmodule VisionCore.Calibration.RecorderTest do
  use ExUnit.Case, async: false

  alias VisionCore.Calibration.{Library, Recorder, Saved, Selection}
  alias VisionCore.Camera.Calibration, as: OwnCalibration
  alias VisionCore.Outputs
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration

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
    built_in = @built_in |> File.read!() |> CameraCalibration.parse()
    [_fx | rest] = built_in.camera_matrix
    %{built_in | camera_matrix: [fx | rest]}
  end

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

    assert [%{name: "2026-11-13 23:28", inserted_at: ~U[2026-11-13 23:28:11Z]}] =
             Library.list("hq")
  end

  test "keeps a committed calibration with the figures it was told to expect, and selects it", %{
    config: config
  } do
    start(config)

    :ok =
      Recorder.expect(
        "hq",
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
    :ok = Recorder.expect("hq", {:record, origin: "dashboard", samples: 41})
    :ok = Recorder.forget("hq")

    commit(config, 580.8)
    assert [%{origin: "imported", samples: nil}] = Library.list("hq")
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

    :ok = Recorder.expect("hq", {:select, older.id})
    commit(config, 580.8)

    assert Library.selected("hq").id == older.id
    assert length(Library.list("hq")) == 2
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

  test "selects nothing for a pair whose stored file of one side gives no calibration", %{
    tmp_dir: tmp_dir
  } do
    fixtures = Path.expand("../../support/calibration", __DIR__)
    store = Path.join(tmp_dir, "pair_store")
    File.mkdir_p!(store)
    File.cp!(Path.join(fixtures, "identity_right.yaml"), Path.join(store, "front_right.yaml"))
    File.write!(Path.join(store, "front_left.yaml"), "camera_matrix:\n  data: [1.0, 2.0]\n")

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

  test "publishes each change of a target's library", %{config: config} do
    start(config)
    Outputs.subscribe(Recorder.changed_key("hq"))

    commit(config, 580.8)
    assert_receive {:"$gen_cast", {:saved_calibrations_changed, "hq"}}

    Recorder.changed("hq")
    assert_receive {:"$gen_cast", {:saved_calibrations_changed, "hq"}}
  end

  test "answers without a recorder running" do
    assert Recorder.expect("hq", {:select, 1}) == :ok
    assert Recorder.forget("hq") == :ok
  end
end
