defmodule VisionApiWeb.ParameterController do
  @moduledoc "The vision parameters (`VisionCore.Parameters`) as JSON:API resources."
  use VisionApiWeb, :controller

  alias VisionApiWeb.{JsonApi, ParameterJSON}
  alias VisionCore.Parameters

  @value_pointer "/data/attributes/value"

  def index(conn, _params) do
    groups = Parameters.groups()

    JsonApi.send_document(conn, 200, %{
      data: groups |> ParameterJSON.parameters() |> Enum.map(&ParameterJSON.parameter/1),
      meta: %{unsaved: ParameterJSON.unsaved(groups)}
    })
  end

  def show(conn, %{"id" => id}) do
    case Parameters.get(id) do
      {:ok, parameter} ->
        JsonApi.send_document(conn, 200, %{data: ParameterJSON.parameter(parameter)})

      {:error, :not_found} ->
        JsonApi.error(conn, 404, "Not Found", "no parameter #{id}")
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- check_resource(params["data"], "parameters", id),
         {:ok, value} <- fetch_value(params["data"]) do
      case Parameters.set(id, value) do
        {:ok, parameter} ->
          JsonApi.send_document(conn, 200, %{data: ParameterJSON.parameter(parameter)})

        {:error, reason} ->
          not_settable(conn, id, reason)
      end
    else
      {:error, status, title, detail, pointer} ->
        JsonApi.error(conn, status, title, detail, pointer)
    end
  end

  defp not_settable(conn, id, reason) do
    case Parameters.get(id) do
      {:error, :not_found} -> JsonApi.error(conn, 404, "Not Found", "no parameter #{id}")
      {:ok, _parameter} -> JsonApi.error(conn, 422, "Invalid value", reason, @value_pointer)
    end
  end

  defp check_resource(%{"type" => type}, expected, _id) when type != expected,
    do: {:error, 409, "Conflict", "type must be #{expected}", "/data/type"}

  defp check_resource(%{"id" => id}, _type, expected) when id != expected,
    do: {:error, 409, "Conflict", "id must be #{expected}", "/data/id"}

  defp check_resource(%{}, _type, _id), do: :ok

  defp check_resource(_data, _type, _id),
    do: {:error, 400, "Bad Request", "data is required", "/data"}

  defp fetch_value(%{"attributes" => %{"value" => value}}), do: {:ok, value}

  defp fetch_value(_data),
    do: {:error, 400, "Bad Request", "data.attributes.value is required", @value_pointer}
end
