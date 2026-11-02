defmodule VisionApiWeb.StageController do
  @moduledoc """
  The vision `stages`, one per `VisionCore.Parameters.Group`: the components
  and pipeline stages, with their parameters when `include=parameters`.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters

  def index(conn, params) do
    case includes(params) do
      {:ok, include_parameters} ->
        render(conn, :index, groups: Parameters.groups(), include_parameters: include_parameters)

      :error ->
        JsonApi.error(conn, 400, "Bad Request", "unsupported include", %{parameter: "include"})
    end
  end

  defp includes(%{"include" => include}) do
    case String.split(include, ",", trim: true) do
      [] -> {:ok, false}
      ["parameters"] -> {:ok, true}
      _unsupported -> :error
    end
  end

  defp includes(_params), do: {:ok, false}
end
