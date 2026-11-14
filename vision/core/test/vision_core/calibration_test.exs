defmodule VisionCore.CalibrationTest do
  use ExUnit.Case, async: false

  alias VisionCore.Calibration

  @moduletag :tmp_dir

  # Names the cameras, which do not run.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  @fixtures Path.expand("../support/calibration", __DIR__)

  defp config(tmp_dir, camera_options \\ []) do
    %VisionCore.Config{
      components: [
        {:stereo,
         [
           driver: Camera,
           prefix: "front",
           left: [calibration_path: Path.join(@fixtures, "identity_left.yaml")],
           right: [calibration_path: Path.join(@fixtures, "identity_right.yaml")]
         ]},
        {:camera,
         [name: :hq, driver: Camera, calibration_store_dir: Path.join(tmp_dir, "store")] ++
           camera_options}
      ]
    }
  end

  test "targets/1 lists the stereo pair by its prefix, then each camera by its name",
       %{tmp_dir: tmp_dir} do
    assert [stereo, camera] = Calibration.targets(config(tmp_dir))

    assert %{id: "front", kind: :stereo, name: nil, labels: ["left", "right"]} = stereo
    assert stereo.servers == [Camera.name_for("left"), Camera.name_for("right")]
    assert length(stereo.frame_keys) == 2

    assert camera == %{
             id: "hq",
             kind: :camera,
             name: :hq,
             labels: ["hq"],
             frame_keys: [{:camera_frame, Camera.name_for("hq")}],
             servers: [Camera.name_for("hq")]
           }
  end

  test "targets/1 is empty for a unit with no camera" do
    assert Calibration.targets(%VisionCore.Config{}) == []
  end

  test "fetch_target/2 finds a target by its id", %{tmp_dir: tmp_dir} do
    assert {:ok, %{kind: :camera}} = Calibration.fetch_target(config(tmp_dir), "hq")
    assert Calibration.fetch_target(config(tmp_dir), "rear") == :error
  end

  test "in_use/2 gives the pair's two cameras, each with the file to save it under",
       %{tmp_dir: tmp_dir} do
    assert {:ok, in_use} = Calibration.in_use(config(tmp_dir), "front")

    assert %{id: "front", kind: :stereo, source: :built_in, can_reset: false} = in_use
    assert is_float(in_use.baseline_m)

    assert [
             %{name: "left", file: "front_left.yaml", yaml: "image_width" <> _},
             %{name: "right", file: "front_right.yaml"}
           ] = in_use.cameras
  end

  test "in_use/2 gives a camera's own calibration, without a baseline", %{tmp_dir: tmp_dir} do
    built_in = Path.join(@fixtures, "identity_left.yaml")

    assert {:ok, in_use} = Calibration.in_use(config(tmp_dir, calibration: built_in), "hq")

    assert %{id: "hq", kind: :camera, source: :built_in, baseline_m: nil} = in_use
    assert [%{name: "hq", file: "hq.yaml", path: ^built_in, calibration: %{}}] = in_use.cameras
  end

  test "in_use/2 and reset/2 do not know another id", %{tmp_dir: tmp_dir} do
    assert Calibration.in_use(config(tmp_dir), "rear") == {:error, :not_found}
    assert Calibration.reset(config(tmp_dir), "rear") == {:error, :not_found}
  end

  test "reset/2 returns a camera to its built-in calibration", %{tmp_dir: tmp_dir} do
    built_in = Path.join(@fixtures, "identity_left.yaml")
    config = config(tmp_dir, calibration: built_in)
    {:ok, %{cameras: [%{calibration: calibration}]}} = Calibration.in_use(config, "hq")
    :ok = VisionCore.Camera.Calibration.commit(config, :hq, calibration)
    assert {:ok, %{source: :stored}} = Calibration.in_use(config, "hq")

    assert :ok = Calibration.reset(config, "hq")
    assert {:ok, %{source: :built_in}} = Calibration.in_use(config, "hq")
  end

  describe "the calibrations kept" do
    alias VisionCore.Calibration.{Library, Recorder, Saved, Selection}
    alias VisionCore.Camera.Calibration, as: OwnCalibration
    alias VisionCore.Outputs
    alias VisionCore.Repo
    alias VisionCore.Ros2.CameraCalibration

    @built_in Path.join(@fixtures, "identity_left.yaml")

    setup %{tmp_dir: tmp_dir} do
      Repo.delete_all(Selection)
      Repo.delete_all(Saved)
      config = config(tmp_dir, calibration: @built_in)
      start_supervised!({Recorder, config: config})
      %{config: config}
    end

    defp calibration(fx) do
      built_in = CameraCalibration.load!(@built_in)
      [_fx | rest] = built_in.camera_matrix
      %{built_in | camera_matrix: [fx | rest]}
    end

    defp commit(config, fx) do
      :ok = OwnCalibration.commit(config, :hq, calibration(fx))
      :sys.get_state(Recorder)
    end

    defp fx_in_use(config) do
      {:ok, %{cameras: [%{calibration: %{camera_matrix: [fx | _rest]}}]}} =
        Calibration.in_use(config, "hq")

      fx
    end

    test "saved/2 lists a target's calibrations, the newest first, the one in force marked", %{
      config: config
    } do
      commit(config, 580.8)
      commit(config, 590.0)

      assert {:ok, [%{saved: %{cameras: [%{fx: 590.0}]}, in_force: true}, %{in_force: false}]} =
               Calibration.saved(config, "hq")

      assert Calibration.saved(config, "front") == {:ok, []}
      assert Calibration.saved(config, "rear") == {:error, :not_found}
    end

    test "use_saved/2 puts a kept calibration back in force", %{config: config} do
      commit(config, 580.8)
      commit(config, 590.0)
      {:ok, [_second, %{saved: first}]} = Calibration.saved(config, "hq")
      Outputs.subscribe(Calibration.changed_key(elem(Calibration.fetch_target(config, "hq"), 1)))

      assert Calibration.use_saved(config, first.id) == :ok
      assert_receive {:"$gen_cast", {:camera_calibration_changed, :hq}}
      :sys.get_state(Recorder)

      assert fx_in_use(config) == 580.8

      assert {:ok, %{saved: %{id: id}, in_force: true}} =
               Calibration.fetch_saved(config, first.id)

      assert id == first.id
      assert {:ok, [%{in_force: false}, %{in_force: true}]} = Calibration.saved(config, "hq")
    end

    test "use_saved/2 selects the calibration asked for among those holding the same figures",
         %{config: config} do
      {:ok, older} = Library.record("hq", [{"hq", calibration(580.8)}], origin: "dashboard")
      {:ok, _newer} = Library.record("hq", [{"hq", calibration(580.8)}], origin: "dashboard")

      assert Calibration.use_saved(config, older.id) == :ok
      :sys.get_state(Recorder)

      assert Library.selected("hq").id == older.id
    end

    test "use_saved/2 refuses a calibration that is not kept, or kept for a target the unit has not",
         %{config: config} do
      {:ok, foreign} = Library.record("rear", [{"rear", calibration(600.0)}], origin: "imported")

      assert Calibration.use_saved(config, -1) == {:error, :not_found}
      assert Calibration.use_saved(config, foreign.id) == {:error, :not_found}
      assert Calibration.fetch_saved(config, foreign.id) == {:error, :not_found}
    end

    test "rename_saved/3 and delete_saved/3 publish the change of the target's library", %{
      config: config
    } do
      commit(config, 580.8)
      commit(config, 590.0)
      {:ok, [_second, %{saved: first}]} = Calibration.saved(config, "hq")
      Outputs.subscribe(Recorder.changed_key("hq"))

      assert {:ok, %{saved: %{name: "Bench"}, in_force: false}} =
               Calibration.rename_saved(config, first.id, "Bench")

      assert_receive {:"$gen_cast", {:saved_calibrations_changed, "hq"}}

      assert Calibration.delete_saved(config, first.id) == :ok
      assert_receive {:"$gen_cast", {:saved_calibrations_changed, "hq"}}
      assert {:ok, [%{in_force: true}]} = Calibration.saved(config, "hq")
    end

    test "delete_saved/3 returns the target to its built-in calibration, then removes the one in force",
         %{config: config} do
      commit(config, 580.8)
      {:ok, [%{saved: saved}]} = Calibration.saved(config, "hq")
      Outputs.subscribe(Recorder.changed_key("hq"))

      assert Calibration.delete_saved(config, saved.id) == :ok

      assert {:ok, %{source: :built_in}} = Calibration.in_use(config, "hq")
      assert Library.fetch(saved.id) == {:error, :not_found}
      assert Library.selected("hq") == nil
      assert_receive {:"$gen_cast", {:saved_calibrations_changed, "hq"}}
      assert Calibration.rename_saved(config, -1, "x") == {:error, :not_found}
    end

    test "delete_saved/3 keeps the calibration in force of a target with no built-in one to return to",
         %{tmp_dir: tmp_dir} do
      config = config(tmp_dir)
      :ok = OwnCalibration.commit(config, :hq, calibration(580.8))
      :sys.get_state(Recorder)
      {:ok, [%{saved: saved, in_force: true}]} = Calibration.saved(config, "hq")

      assert Calibration.delete_saved(config, saved.id) == {:error, :in_force}

      assert {:ok, %{source: :stored}} = Calibration.in_use(config, "hq")
      assert {:ok, _saved} = Library.fetch(saved.id)
    end

    test "delete_saved/3 keeps the calibration in force when the return to the built-in one fails",
         %{config: config, tmp_dir: tmp_dir} do
      commit(config, 580.8)
      {:ok, [%{saved: saved}]} = Calibration.saved(config, "hq")
      store = Path.join(tmp_dir, "store")
      File.chmod!(store, 0o500)
      on_exit(fn -> File.chmod(store, 0o700) end)

      assert {:error, {:reset, "cannot remove " <> _reason}} =
               Calibration.delete_saved(config, saved.id)

      assert {:ok, %{source: :stored}} = Calibration.in_use(config, "hq")
      assert Library.selected("hq").id == saved.id
    end

    test "saved/2 gives each camera's YAML with the file to save it under, as the calibration in use",
         %{config: config} do
      left = calibration(580.8)
      right = calibration(590.0)

      {:ok, _pair} =
        Library.record("front", [{"left", left}, {"right", right}], origin: "dashboard")

      commit(config, 600.5)

      assert {:ok,
              [%{files: [%{name: "left", file: "front_left.yaml", yaml: left_yaml}, right_file]}]} =
               Calibration.saved(config, "front")

      assert %{name: "right", file: "front_right.yaml", yaml: right_yaml} = right_file
      assert left_yaml == CameraCalibration.to_yaml(left, "front_left")
      assert {:ok, %{camera_matrix: [590.0 | _rest]}} = CameraCalibration.parse(right_yaml)

      assert {:ok, [%{files: [%{name: "hq", file: "hq.yaml", yaml: hq_yaml}]}]} =
               Calibration.saved(config, "hq")

      assert hq_yaml == CameraCalibration.to_yaml(calibration(600.5), "hq")
    end
  end
end
