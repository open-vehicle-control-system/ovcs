defmodule VisionApiWeb.ParameterController do
  @moduledoc "The vision parameters (`VisionCore.Parameters`) as JSON:API resources."
  use VisionApiWeb, :controller

  alias VisionApiWeb.{JsonApi, ParameterJSON}
  alias VisionCore.Parameters

  def index(conn, _params) do
    parameters = Parameters.groups() |> Enum.flat_map(& &1.parameters)

    JsonApi.send_document(conn, 200, %{
      data: Enum.map(parameters, &ParameterJSON.parameter/1),
      meta: %{unsaved: Parameters.unsaved_count()}
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
end
