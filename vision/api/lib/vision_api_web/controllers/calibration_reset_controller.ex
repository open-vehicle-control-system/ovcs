defmodule VisionApiWeb.CalibrationResetController do
  @moduledoc """
  Serves `calibration-resets`: creating one returns the `calibration` it
  names to its built-in one, answering once the unit has taken it.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationSessionJSON, CalibrationUnit, JsonApi}
  alias VisionCore.Calibration
  alias VisionCore.Calibration.Session

  @type_name "calibration-resets"

  plug :put_view, json: CalibrationSessionJSON, jsonapi: CalibrationSessionJSON

  def create(conn, _params) do
    with :ok <- CalibrationUnit.check_session(),
         {:ok, data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, id} <- CalibrationUnit.fetch_target_id(data),
         :ok <- CalibrationUnit.check_idle("Not reset"),
         :ok <- reset(id) do
      conn
      |> put_status(:created)
      |> render(:show, type: @type_name, id: JsonApi.action_id(), session: Session.state())
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end

  # A reset the target refuses, as one with nothing stored, is a 422; one the unit fails, a 500.
  defp reset(id) do
    config = CalibrationUnit.config()
    resettable? = match?({:ok, %{can_reset: true}}, Calibration.in_use(config, id))

    case reset_task(config, id) do
      {:error, :not_found} -> CalibrationUnit.target_not_found(id)
      {:error, reason} when resettable? -> {:error, 500, reason, []}
      outcome -> CalibrationUnit.check_outcome(outcome, 422, "Not reset")
    end
  end

  # Outlives the request: a reset may wait for the stereo unit to restart.
  defp reset_task(config, id) do
    case CalibrationUnit.run("the reset", fn -> Calibration.reset(config, id) end) do
      {:ok, outcome} -> outcome
      :failed -> {:failed, "the reset failed; the log says why"}
    end
  end
end
