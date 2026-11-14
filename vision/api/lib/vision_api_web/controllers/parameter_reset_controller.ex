defmodule VisionApiWeb.ParameterResetController do
  @moduledoc """
  Serves `parameter-resets`: creating one returns the parameter or stage its
  `target` names, or every parameter without one, to its defaults.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{JsonApi, ParameterChangeJSON}
  alias VisionCore.Parameters

  @type_name "parameter-resets"
  @target_types %{"stages" => :group, "parameters" => :parameter}

  plug :put_view, json: ParameterChangeJSON, jsonapi: ParameterChangeJSON

  def create(conn, _params) do
    with {:ok, data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, scope} <- scope(data),
         {:ok, ids} <- reset(scope) do
      conn
      |> put_status(:created)
      |> render(:show, type: @type_name, id: JsonApi.action_id(), parameters: ids)
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end

  defp reset(scope) do
    case Parameters.reset(scope) do
      {:ok, ids} -> {:ok, ids}
      {:error, :not_found} -> {:error, 404, not_found(scope), []}
      {:error, reason} -> {:error, 422, reason, [title: "Not reset"]}
    end
  end

  defp scope(%{"relationships" => relationships}), do: target(relationships)
  defp scope(_data), do: {:ok, :all}

  defp target(%{"target" => %{"data" => %{"type" => type, "id" => id}}})
       when is_map_key(@target_types, type) and is_binary(id),
       do: {:ok, {Map.fetch!(@target_types, type), id}}

  defp target(%{"target" => %{"data" => _data}}),
    do:
      {:error, 400, "target must be a parameter or a stage",
       [source: "/data/relationships/target/data"]}

  defp target(%{"target" => _target}),
    do: {:error, 400, "target must hold data", [source: "/data/relationships/target"]}

  defp target(_relationships),
    do: {:error, 400, "relationships must hold a target", [source: "/data/relationships"]}

  defp not_found({:group, id}), do: "no stage #{id}"
  defp not_found({:parameter, id}), do: "no parameter #{id}"
end
