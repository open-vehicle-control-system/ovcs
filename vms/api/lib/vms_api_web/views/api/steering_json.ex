defmodule VmsApiWeb.Api.SteeringJSON do
  use VmsApiWeb, :view

  def render("steering.json", %{lws_status: lws_status}) do
    %{
      type: "steering",
      id:    "steering",
      attributes: %{
        lwsAngle: lws_status.angle,
        lwsAngularSpeed: lws_status.angular_speed,
        lwsTrimmingValid: lws_status.trimming_valid,
        lwsCalibrationValid: lws_status.calibration_valid,
        lwsSensorReady: lws_status.sensor_ready
      }
    }
  end
end
