defmodule VmsApiWeb.Api.CarControlsJSON do
  use VmsApiWeb, :view

  def render("car_controls.json", %{car_controls: car_controls}) do
    %{
      type: "carControls",
      id:    "carControls",
      attributes: %{
        throttle: car_controls.throttle,
        calibrationStatus: car_controls.calibration_status,
        rawMaxThrottle: car_controls.raw_max_throttle,
        highRawThrottleA: car_controls.high_raw_throttle_a,
        highRawThrottleB: car_controls.high_raw_throttle_b,
        lowRawThrottleA: car_controls.low_raw_throttle_a,
        lowRawThrottleB: car_controls.low_raw_throttle_b,
        rawThrottleA: car_controls.raw_throttle_a,
        rawThrottleB: car_controls.raw_throttle_b,
        requestedGear: car_controls.requested_gear,
      }
    }
  end
end
