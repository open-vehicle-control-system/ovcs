defmodule VisionApiWeb.ParameterSaveController do
  @moduledoc "Serves `parameter-saves`: creating one saves the vision parameters' unsaved values."
  use VisionApiWeb, :controller

  alias VisionApiWeb.{JsonApi, ParameterChangeJSON}
  alias VisionCore.Parameters

  @type_name "parameter-saves"

  plug :put_view, json: ParameterChangeJSON, jsonapi: ParameterChangeJSON

  def create(conn, _params) do
    with {:ok, _data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, ids} <- save() do
      conn
      |> put_status(:created)
      |> render(:show, type: @type_name, id: JsonApi.action_id(), parameters: ids)
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end

  defp save do
    case Parameters.save() do
      {:ok, ids} -> {:ok, ids}
      {:error, reason} -> {:error, 503, reason, [title: "Saved values unavailable"]}
    end
  end
end
