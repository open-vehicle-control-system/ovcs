defmodule VisionApiWeb.CalibrationApplyController do
  @moduledoc """
  Serves `calibration-applies`: creating one begins the apply of the solved
  calibration, whose outcome comes through the `calibration` channel.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationSessionJSON, CalibrationUnit, JsonApi}
  alias VisionCore.Calibration.Session

  @type_name "calibration-applies"

  plug :put_view, json: CalibrationSessionJSON, jsonapi: CalibrationSessionJSON

  def create(conn, _params) do
    with :ok <- CalibrationUnit.check_session(),
         {:ok, _data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         :ok <- CalibrationUnit.check_outcome(Session.apply(), 422, "Not applied") do
      conn
      |> put_status(:accepted)
      |> render(:show, type: @type_name, id: JsonApi.action_id(), session: Session.state())
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end
end
