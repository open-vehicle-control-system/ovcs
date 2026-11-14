defmodule VisionCore.Camera.CalibrationTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Calibration
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration

  @moduletag :tmp_dir

  defmodule Driver do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  @calibration %CameraCalibration{
    width: 1014,
    height: 760,
    distortion_model: "plumb_bob",
    distortion_coefficients: [0.1, -0.2, 0.0, 0.0, 0.0],
    camera_matrix: [900.0, 0.0, 507.0, 0.0, 900.0, 380.0, 0.0, 0.0, 1.0],
    rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    projection_matrix: [880.0, 0.0, 507.0, 0.0, 0.0, 880.0, 380.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  }

  setup %{tmp_dir: tmp_dir} do
    built_in = Path.join(tmp_dir, "built_in.yaml")
    store_dir = Path.join(tmp_dir, "store")

    {:ok,
     built_in: built_in, store_dir: store_dir, stored: Path.join(store_dir, "camera_hq.yaml")}
  end

  defp config(camera_options),
    do: %VisionCore.Config{components: [{:camera, [name: :hq, driver: Driver] ++ camera_options}]}

  defp write_built_in(path),
    do: File.write!(path, CameraCalibration.to_yaml(%{@calibration | width: 2028}, "hq"))

  describe "in_use/2" do
    test "reads the built-in calibration, with nothing to go back to", context do
      write_built_in(context.built_in)
      config = config(calibration: context.built_in, calibration_store_dir: context.store_dir)

      assert {:ok, in_use} = Calibration.in_use(config, :hq)
      assert in_use.source == :built_in
      assert in_use.stored_at == nil
      refute in_use.can_reset
      assert in_use.camera.path == context.built_in
      assert in_use.camera.calibration.width == 2028
      assert in_use.camera.yaml =~ "image_width: 2028"
    end

    test "has no calibration without a file", context do
      config = config(calibration: context.built_in)

      assert {:ok, %{source: :none, can_reset: false, camera: %{calibration: nil, yaml: nil}}} =
               Calibration.in_use(config, :hq)
    end

    test "does not know a camera the configuration has not" do
      assert Calibration.in_use(config([]), :usb) == {:error, :not_found}
    end

    test "says why a file it cannot read or parse gives no calibration", context do
      config = config(calibration: context.built_in, calibration_store_dir: context.store_dir)
      write_built_in(context.built_in)

      File.mkdir_p!(context.stored)
      assert {:ok, unreadable} = Calibration.in_use(config, :hq)
      assert unreadable.error =~ "cannot read"
      assert %{calibration: nil, yaml: nil} = unreadable.camera
      File.rmdir!(context.stored)

      File.write!(context.stored, "camera_matrix:\n  data: [1, 2]\n")
      assert {:ok, malformed} = Calibration.in_use(config, :hq)
      assert malformed.error =~ "camera matrix"
      assert malformed.camera.calibration == nil
      assert malformed.can_reset

      File.rm!(context.stored)
      assert {:ok, %{error: nil}} = Calibration.in_use(config, :hq)
    end
  end

  describe "commit/3" do
    test "writes the calibration to the store, which takes precedence, and tells the change",
         context do
      write_built_in(context.built_in)
      config = config(calibration: context.built_in, calibration_store_dir: context.store_dir)
      :ok = Outputs.subscribe(Calibration.changed_key(:hq))

      assert :ok = Calibration.commit(config, :hq, @calibration)

      assert_receive {:"$gen_cast", {:camera_calibration_changed, :hq}}
      assert context.stored |> File.read!() |> CameraCalibration.parse() == {:ok, @calibration}
      refute File.exists?(context.stored <> ".tmp")

      assert {:ok, in_use} = Calibration.in_use(config, :hq)
      assert in_use.source == :stored
      assert %DateTime{} = in_use.stored_at
      assert in_use.can_reset
      assert in_use.camera.calibration.width == 1014
    end

    test "without a store, writes the camera's calibration path", context do
      config = config(calibration: context.built_in)

      assert :ok = Calibration.commit(config, :hq, @calibration)
      assert context.built_in |> File.read!() |> CameraCalibration.parse() == {:ok, @calibration}
    end

    test "waits for a commit or a reset of the same camera to end", context do
      config = config(calibration: context.built_in, calibration_store_dir: context.store_dir)
      lock = {{Calibration, :hq}, self()}
      true = :global.set_lock(lock, [node()])

      commit = Task.async(fn -> Calibration.commit(config, :hq, @calibration) end)
      refute Task.yield(commit, 100)
      refute File.exists?(context.stored)

      true = :global.del_lock(lock, [node()])
      assert Task.await(commit) == :ok
      assert File.exists?(context.stored)
    end

    test "refuses a camera with nowhere to write, and one it does not know" do
      assert {:error, reason} = Calibration.commit(config([]), :hq, @calibration)
      assert reason =~ "no calibration path"
      assert Calibration.commit(config([]), :usb, @calibration) == {:error, :not_found}
    end
  end

  describe "reset/2" do
    test "removes the stored calibration, back to the built-in one, and tells the change",
         context do
      write_built_in(context.built_in)
      config = config(calibration: context.built_in, calibration_store_dir: context.store_dir)
      :ok = Calibration.commit(config, :hq, @calibration)
      :ok = Outputs.subscribe(Calibration.changed_key(:hq))

      assert :ok = Calibration.reset(config, :hq)

      assert_receive {:"$gen_cast", {:camera_calibration_changed, :hq}}
      refute File.exists?(context.stored)
      assert {:ok, %{source: :built_in}} = Calibration.in_use(config, :hq)
    end

    test "refuses with nothing stored, without a store, or without a built-in calibration",
         context do
      write_built_in(context.built_in)
      stored = config(calibration: context.built_in, calibration_store_dir: context.store_dir)
      assert {:error, "nothing is stored"} = Calibration.reset(stored, :hq)

      assert {:error, "the camera has no calibration store"} =
               Calibration.reset(config(calibration: context.built_in), :hq)

      no_built_in = config(calibration_store_dir: context.store_dir)
      :ok = Calibration.commit(no_built_in, :hq, @calibration)

      assert {:error, "there is no built-in calibration to return to"} =
               Calibration.reset(no_built_in, :hq)

      assert File.exists?(context.stored)
    end
  end
end
