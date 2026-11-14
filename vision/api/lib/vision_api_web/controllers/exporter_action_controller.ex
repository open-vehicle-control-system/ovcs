defmodule VisionApiWeb.ExporterActionController do
  @moduledoc """
  Serves `exporter-actions`: creating one runs an exporter's action with the
  document's `attributes` (`VisionCore.Exporters.action/4`).
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Exporters

  @document_type "exporter-actions"
  @timeout_ms 60_000

  def create(conn, %{"id" => id, "name" => name}) do
    case fetch_attributes(JsonApi.document(conn)) do
      {:ok, attributes} ->
        id |> Exporters.action(name, attributes, @timeout_ms) |> answer(conn, id, name)

      refusal ->
        JsonApi.refuse(conn, refusal)
    end
  end

  defp answer({:ok, result}, conn, _id, _name) do
    render(conn, :show, type: @document_type, id: JsonApi.action_id(), result: result)
  end

  defp answer({:file, filename, content_type, contents}, conn, _id, _name),
    do: send_download(conn, {:binary, contents}, filename: filename, content_type: content_type)

  defp answer({:error, :not_found}, conn, id, _name),
    do: JsonApi.error(conn, 404, "no exporter #{id}")

  defp answer({:error, :unknown_action}, conn, id, name),
    do: JsonApi.error(conn, 404, "exporter #{id} has no action #{name}")

  defp answer({:error, :busy}, conn, id, _name),
    do: JsonApi.error(conn, 409, "exporter #{id} is busy", title: "Busy")

  defp answer({:error, :not_running}, conn, id, _name),
    do: JsonApi.error(conn, 503, "exporter #{id} is not running", title: "Exporter not running")

  defp answer({:error, {:timeout, message}}, conn, _id, _name),
    do: JsonApi.error(conn, 504, message, title: "Action timed out")

  defp answer({:error, {:refused, reason}}, conn, _id, _name),
    do: JsonApi.error(conn, 422, reason, title: "Action refused")

  defp answer({:error, {:failed, message}}, conn, _id, _name),
    do: JsonApi.error(conn, 500, message, title: "Action failed")

  defp fetch_attributes(document) do
    with {:ok, data} <- JsonApi.fetch_created(document, @document_type) do
      case Map.get(data, "attributes", %{}) do
        attributes when is_map(attributes) ->
          {:ok, attributes}

        _other ->
          {:error, 400, "attributes must be an object", [source: "/data/attributes"]}
      end
    end
  end
end
