defmodule VisionApiWeb.ParameterDiscardController do
  @moduledoc "Serves `parameter-discards`: creating one puts the vision parameters' unsaved values back."
  use VisionApiWeb, :controller

  alias VisionApiWeb.{JsonApi, ParameterChangeJSON}
  alias VisionCore.Parameters

  @type_name "parameter-discards"

  plug :put_view, json: ParameterChangeJSON, jsonapi: ParameterChangeJSON

  def create(conn, _params) do
    with {:ok, _data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, ids} <- Parameters.discard() do
      conn
      |> put_status(:created)
      |> render(:show, type: @type_name, id: JsonApi.action_id(), parameters: ids)
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end
end
