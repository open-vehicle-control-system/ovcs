defmodule VisionApiWeb.CalibrationCancelController do
  @moduledoc "Serves `calibration-cancels`: creating one ends the calibration session."
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationSessionJSON, CalibrationUnit, JsonApi}
  alias VisionCore.Calibration.Session

  @type_name "calibration-cancels"

  plug :put_view, json: CalibrationSessionJSON, jsonapi: CalibrationSessionJSON

  def create(conn, _params) do
    with :ok <- CalibrationUnit.check_session(),
         {:ok, _data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         :ok <- CalibrationUnit.check_outcome(Session.cancel(), 409, "Not cancelled") do
      conn
      |> put_status(:created)
      |> render(:show, type: @type_name, id: JsonApi.action_id(), session: Session.state())
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end
end
