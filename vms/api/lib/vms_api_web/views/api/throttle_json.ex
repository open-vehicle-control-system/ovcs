defmodule VmsApiWeb.Api.ThrottleJSON do
  use VmsApiWeb, :view

  def render("throttle.json", %{throttle: throttle}) do
    %{
      type: "throttle",
      id:    "throttle",
      attributes: %{
        throttle: throttle.requested_throttle,
        calibrationStatus: throttle.throttle_calibration_status,
        rawMaxThrottle: throttle.raw_max_throttle,
        highRawThrottleA: throttle.high_raw_throttle_a,
        highRawThrottleB: throttle.high_raw_throttle_b,
        lowRawThrottleA: throttle.low_raw_throttle_a,
        lowRawThrottleB: throttle.low_raw_throttle_b,
        rawThrottleA: throttle.raw_throttle_a,
        rawThrottleB: throttle.raw_throttle_b,
      }
    }
  end
end
