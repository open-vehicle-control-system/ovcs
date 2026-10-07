defmodule RosBridge.StereoCamera.SupervisorTest do
  use ExUnit.Case, async: true

  alias RosBridge.StereoCamera.Supervisor, as: StereoSupervisor

  @moduletag :tmp_dir

  @left [calibration_path: "/rom/stereo_left.yaml"]
  @right [calibration_path: "/rom/stereo_right.yaml"]

  describe "use_stored_calibration/4" do
    test "leaves the sides alone without a store", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "stereo_left.yaml"), "")
      File.write!(Path.join(dir, "stereo_right.yaml"), "")

      assert StereoSupervisor.use_stored_calibration(@left, @right, nil, "stereo") ==
               {@left, @right}
    end

    test "keeps the shipped calibration while the store is empty", %{tmp_dir: dir} do
      {left, right} = StereoSupervisor.use_stored_calibration(@left, @right, dir, "stereo")

      assert left[:calibration_path] == "/rom/stereo_left.yaml"
      assert right[:calibration_path] == "/rom/stereo_right.yaml"
      assert left[:calibration_store_path] == Path.join(dir, "stereo_left.yaml")
      assert right[:calibration_store_path] == Path.join(dir, "stereo_right.yaml")
    end

    test "does not pair one stored side with a shipped one", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "stereo_left.yaml"), "")

      {left, right} = StereoSupervisor.use_stored_calibration(@left, @right, dir, "stereo")

      assert left[:calibration_path] == "/rom/stereo_left.yaml"
      assert right[:calibration_path] == "/rom/stereo_right.yaml"
    end

    test "uses the stored calibration once both sides are stored", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "stereo_left.yaml"), "")
      File.write!(Path.join(dir, "stereo_right.yaml"), "")

      {left, right} = StereoSupervisor.use_stored_calibration(@left, @right, dir, "stereo")

      assert left[:calibration_path] == Path.join(dir, "stereo_left.yaml")
      assert right[:calibration_path] == Path.join(dir, "stereo_right.yaml")
    end
  end

  describe "reload_stored_calibration/3" do
    test "waits for the second side before reloading", %{tmp_dir: dir} do
      left = Path.join(dir, "stereo_left.yaml")
      File.write!(left, "")

      assert StereoSupervisor.reload_stored_calibration(
               :no_backend,
               left,
               Path.join(dir, "stereo_right.yaml")
             ) == :ok
    end
  end
end
