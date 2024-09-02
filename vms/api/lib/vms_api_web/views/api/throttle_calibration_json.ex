defmodule VmsApiWeb.Api.ThrottleCalibrationJSON do
  use VmsApiWeb, :view

  def render("show.json", %{throttle_calibration_status: throttle_calibration_status}) do
    %{
      data: render_one(throttle_calibration_status, __MODULE__, "throttle_calibration.json", as: :throttle_calibration_status)
    }
  end

  def render("create.json", %{throttle_calibration_status: throttle_calibration_status}) do
    %{
      data: render_one(throttle_calibration_status, __MODULE__, "throttle_calibration.json", as: :throttle_calibration_status)
    }
  end

  def render("throttle_calibration.json", %{throttle_calibration_status: throttle_calibration_status}) do
    %{
      type: "throttleCalibration",
      id:    "throttleCalibration",
      attributes: %{
        status: throttle_calibration_status
      }
    }
  end
end
