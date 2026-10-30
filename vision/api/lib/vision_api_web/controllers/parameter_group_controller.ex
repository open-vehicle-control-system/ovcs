defmodule VisionApiWeb.ParameterGroupController do
  @moduledoc "The vision parameter groups, with their parameters when `include=parameters`."
  use VisionApiWeb, :controller

  alias VisionApiWeb.{JsonApi, ParameterJSON}
  alias VisionCore.Parameters

  def index(conn, params) do
    groups = Parameters.groups()

    document = %{
      data: Enum.map(groups, &ParameterJSON.group/1),
      meta: %{unsaved: Parameters.unsaved_count()}
    }

    document =
      if included?(params),
        do:
          Map.put(
            document,
            :included,
            groups |> Enum.flat_map(& &1.parameters) |> Enum.map(&ParameterJSON.parameter/1)
          ),
        else: document

    JsonApi.send_document(conn, 200, document)
  end

  defp included?(%{"include" => include}), do: "parameters" in String.split(include, ",")
  defp included?(_params), do: false
end
