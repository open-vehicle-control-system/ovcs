defmodule VisionApiWeb.StageController do
  @moduledoc """
  The vision `stages`, one per `VisionCore.Parameters.Group`: the components
  and pipeline stages, with their parameters when `include=parameters`.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{JsonApi, ParameterPresenter, StagePresenter}
  alias VisionCore.Parameters

  def index(conn, params) do
    case includes(params) do
      {:ok, include?} ->
        send_stages(conn, include?)

      :error ->
        JsonApi.error(conn, 400, "Bad Request", "unsupported include", %{parameter: "include"})
    end
  end

  defp send_stages(conn, include?) do
    groups = Parameters.groups()

    document = %{
      data: Enum.map(groups, &StagePresenter.present/1),
      meta: ParameterPresenter.meta(groups)
    }

    document =
      if include? do
        Map.put(document, :included, ParameterPresenter.present_all(groups))
      else
        document
      end

    JsonApi.send_document(conn, 200, document)
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
