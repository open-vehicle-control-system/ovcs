defmodule VmsApiWeb.Api.SteeringAngleSensorCalibrationJSON do
  use VmsApiWeb, :view

  def render("create.json", %{}) do
    %{
      data: render_one(:ok, __MODULE__, "steering_angle_sensor_calibration.json", as: :steering_angle_sensor_calibration)
    }
  end

  def render("steering_angle_sensor_calibration.json", %{steering_angle_sensor_calibration: steering_angle_sensor_calibration}) do
    %{
      type: "steeringAngleSensorCalibration",
      id:    "steeringAngleSensorCalibration",
      attributes: %{
        status: steering_angle_sensor_calibration
      }
    }
  end
end
