defmodule RosBridge.StereoCamera.SupervisorTest do
  use ExUnit.Case, async: true

  alias RosBridge.StereoCamera.Supervisor, as: StereoSupervisor

  @moduletag :tmp_dir

  @left_options [calibration_path: "/rom/stereo_left.yaml"]
  @right_options [calibration_path: "/rom/stereo_right.yaml"]

  describe "use_stored_calibration/4" do
    test "leaves the sides alone without a store", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")
      File.write!(Path.join(tmp_dir, "stereo_right.yaml"), "")

      assert StereoSupervisor.use_stored_calibration(@left_options, @right_options, nil, "stereo") ==
               {@left_options, @right_options}
    end

    test "keeps the shipped calibration while the store is empty", %{tmp_dir: tmp_dir} do
      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == "/rom/stereo_left.yaml"
      assert right[:calibration_path] == "/rom/stereo_right.yaml"
      assert left[:calibration_store_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert right[:calibration_store_path] == Path.join(tmp_dir, "stereo_right.yaml")
    end

    test "does not pair one stored side with a shipped one", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")

      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == "/rom/stereo_left.yaml"
      assert right[:calibration_path] == "/rom/stereo_right.yaml"
    end

    test "uses the stored calibration once both sides are stored", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")
      File.write!(Path.join(tmp_dir, "stereo_right.yaml"), "")

      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert right[:calibration_path] == Path.join(tmp_dir, "stereo_right.yaml")
    end
  end

  describe "reload_stored_calibration/3" do
    test "waits for the second side before reloading", %{tmp_dir: tmp_dir} do
      left_path = Path.join(tmp_dir, "stereo_left.yaml")
      File.write!(left_path, "")

      assert StereoSupervisor.reload_stored_calibration(
               :no_backend,
               left_path,
               Path.join(tmp_dir, "stereo_right.yaml")
             ) == :ok
    end
  end
end
