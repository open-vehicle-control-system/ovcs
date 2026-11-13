defmodule VisionApiWeb.ParameterController do
  @moduledoc """
  The vision parameters (`VisionCore.Parameters`) as JSON:API resources.
  An update is read from the JSON body only.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters

  @value_pointer "/data/attributes/value"

  def index(conn, _params), do: render(conn, :index, groups: Parameters.groups())

  def show(conn, %{"id" => id}) do
    case Parameters.get(id) do
      {:ok, parameter} ->
        render(conn, :show, parameter: parameter)

      {:error, :not_found} ->
        JsonApi.error(conn, 404, "Not Found", "no parameter #{id}")
    end
  end

  def update(conn, %{"id" => id}) do
    data = JsonApi.document(conn)["data"]

    with :ok <- JsonApi.check_identity(data, "parameters", id),
         {:ok, value} <- fetch_value(data) do
      case Parameters.set(id, value) do
        {:ok, parameter} ->
          render(conn, :show, parameter: parameter)

        {:error, :not_found} ->
          JsonApi.error(conn, 404, "Not Found", "no parameter #{id}")

        {:error, reason} ->
          JsonApi.error(conn, 422, "Invalid value", reason, @value_pointer)
      end
    else
      {:error, status, title, detail, pointer} ->
        JsonApi.error(conn, status, title, detail, pointer)
    end
  end

  defp fetch_value(%{"attributes" => %{"value" => value}}), do: {:ok, value}

  defp fetch_value(_data),
    do: {:error, 400, "Bad Request", "data.attributes.value is required", @value_pointer}
end
