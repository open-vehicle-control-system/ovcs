defmodule VisionCore.Models.KeptCalibrationIdTest do
  use ExUnit.Case, async: true

  alias VisionCore.Models.KeptCalibrationId

  @stereo Ecto.ParameterizedType.init(KeptCalibrationId, kind: "stereo")

  test "writes a row's id after its kind, and reads it back" do
    assert Ecto.Type.load(@stereo, 12) == {:ok, "stereo-12"}
    assert Ecto.Type.dump(@stereo, "stereo-12") == {:ok, 12}
    assert Ecto.Type.cast(@stereo, "stereo-12") == {:ok, "stereo-12"}
  end

  test "refuses another kind's id, or an id written another way" do
    for id <- ["camera-12", "stereo-012", "stereo-+12", "stereo-0", "stereo-", "12", 12] do
      assert Ecto.Type.cast(@stereo, id) == :error
    end
  end

  test "parses an id into its kind and its row's id" do
    assert KeptCalibrationId.parse("pose-3") == {:ok, "pose", 3}
    assert KeptCalibrationId.parse("camera-12") == {:ok, "camera", 12}
    assert KeptCalibrationId.parse("lens-12") == :error
    assert KeptCalibrationId.parse("stereo-99999999999999999999") == :error
    assert KeptCalibrationId.parse(-1) == :error
  end
end
