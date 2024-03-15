defmodule VmsApiWeb.Api.CalibrationJSON do
  use VmsApiWeb, :view

  def render("show.json", %{calibration_status: calibration_status}) do
    %{
      data: render_one(calibration_status, __MODULE__, "calibration.json", as: :calibration_status)
    }
  end

  def render("create.json", %{calibration_status: calibration_status}) do
    %{
      data: render_one(calibration_status, __MODULE__, "calibration.json", as: :calibration_status)
    }
  end

  def render("calibration.json", %{calibration_status: calibration_status}) do
    %{
      type: "calibrationStatus",
      id:    "calibrationStatus",
      attributes: %{
        status: calibration_status
      }
    }
  end
end
