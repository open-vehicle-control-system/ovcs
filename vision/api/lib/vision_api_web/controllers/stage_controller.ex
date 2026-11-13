defmodule VisionApiWeb.StageController do
  @moduledoc """
  The vision `stages`, one per `VisionCore.Parameters.Group`: the components
  and pipeline stages, with their parameters when `include=parameters`.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters

  def index(conn, params) do
    case JsonApi.includes(params, ["parameters"]) do
      {:ok, includes} ->
        render(conn, :index, groups: Parameters.groups(), include_parameters: includes != [])

      :error ->
        JsonApi.error(conn, 400, "unsupported include", source: %{parameter: "include"})
    end
  end
end
