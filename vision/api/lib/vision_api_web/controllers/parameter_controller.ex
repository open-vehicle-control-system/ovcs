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
        JsonApi.error(conn, 404, "no parameter #{id}")
    end
  end

  def update(conn, %{"id" => id}) do
    data = JsonApi.document(conn)["data"]

    with :ok <- JsonApi.check_identity(data, "parameters", id),
         {:ok, value} <- JsonApi.fetch_attribute(data, "value") do
      case Parameters.set(id, value) do
        {:ok, parameter} ->
          render(conn, :show, parameter: parameter)

        {:error, :not_found} ->
          JsonApi.error(conn, 404, "no parameter #{id}")

        {:error, reason} ->
          JsonApi.error(conn, 422, reason, source: @value_pointer, title: "Invalid value")
      end
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end
end
