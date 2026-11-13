defmodule VisionCore.Camera.PoseTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Pose

  @moduletag :tmp_dir

  defp write(tmp_dir, yaml) do
    path = Path.join(tmp_dir, "pose.yaml")
    File.write!(path, yaml)
    path
  end

  test "reads the rotation, row-major, and the translation in metres, as floats", %{
    tmp_dir: tmp_dir
  } do
    path =
      write(tmp_dir, """
      # From the rectified left optical frame to the camera's optical frame.
      rotation: [1, 0, 0, 0, 0.98, -0.2, 0, 0.2, 0.98]
      translation: [-0.1, 0.02, 1e-3]
      rms_px: 0.4
      """)

    assert Pose.load(path) ==
             {:ok,
              %Pose{
                rotation: [1.0, 0.0, 0.0, 0.0, 0.98, -0.2, 0.0, 0.2, 0.98],
                translation: [-0.1, 0.02, 0.001]
              }}
  end

  test "reads the YAML scripts/camera_pose.py writes" do
    path = Path.expand("../../support/calibration/camera_pose_hq.yaml", __DIR__)

    assert {:ok, %Pose{rotation: [r00 | _] = rotation, translation: translation}} =
             Pose.load(path)

    assert length(rotation) == 9
    assert_in_delta r00, 0.9955536329797132, 1.0e-15
    assert translation == [-0.12, 0.03, 0.01]
  end

  test "a missing file is the reason File gives", %{tmp_dir: tmp_dir} do
    assert Pose.load(Path.join(tmp_dir, "none.yaml")) == {:error, :enoent}
  end

  test "refuses a rotation or translation of the wrong count, a missing one, or text", %{
    tmp_dir: tmp_dir
  } do
    for yaml <- [
          "rotation: [1, 0, 0, 0, 1, 0, 0, 0]\ntranslation: [0, 0, 0]\n",
          "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, 0]\n",
          "translation: [0, 0, 0]\n",
          "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, zero, 0]\n",
          "rotation: [1, 0, 0\n",
          "- 1\n"
        ] do
      assert {:error, {:malformed, reason}} = Pose.load(write(tmp_dir, yaml)), yaml
      assert is_binary(reason)
    end
  end
end
