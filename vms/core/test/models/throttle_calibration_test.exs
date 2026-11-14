defmodule VmsCore.Models.ThrottleCalibrationTest do
  use ExUnit.Case, async: true

  alias VmsCore.Models.ThrottleCalibration

  test "takes a calibration value by key" do
    changeset =
      ThrottleCalibration.changeset(%ThrottleCalibration{}, %{
        key: "low_raw_throttle_a",
        value: 812
      })

    assert changeset.valid?
    assert changeset.changes == %{key: "low_raw_throttle_a", value: 812}
  end
end
