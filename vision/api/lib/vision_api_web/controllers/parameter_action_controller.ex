defmodule VisionApiWeb.ParameterActionController do
  @moduledoc """
  Save, discard and reset of the vision parameters, created as action
  resources. A reset targets one of the `parameters` or `stages`, or every
  parameter without a target. The action is read from the JSON body only:
  a form or a query string, which another site's page can send without
  asking, is refused.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters

  @target_types %{"stages" => :group, "parameters" => :parameter}

  def save(conn, _params) do
    act(conn, "parameter-saves", fn _data ->
      case Parameters.save() do
        {:ok, ids} -> {:ok, ids}
        {:error, reason} -> {:error, 503, "Saved values unavailable", reason, nil}
      end
    end)
  end

  def discard(conn, _params) do
    act(conn, "parameter-discards", fn _data -> Parameters.discard() end)
  end

  def reset(conn, _params) do
    act(conn, "parameter-resets", fn data ->
      with {:ok, scope} <- scope(data) do
        case Parameters.reset(scope) do
          {:ok, ids} -> {:ok, ids}
          {:error, :not_found} -> {:error, 404, "Not Found", not_found(scope), nil}
          {:error, reason} -> {:error, 422, "Not reset", reason, nil}
        end
      end
    end)
  end

  defp act(conn, type, run) do
    with {:ok, data} <- fetch_data(JsonApi.document(conn), type),
         {:ok, ids} <- run.(data) do
      id = Integer.to_string(System.unique_integer([:positive, :monotonic]))

      conn
      |> put_status(:created)
      |> render(:show, type: type, id: id, parameters: ids)
    else
      {:error, status, title, detail, pointer} ->
        JsonApi.error(conn, status, title, detail, pointer)
    end
  end

  defp fetch_data(%{"data" => %{"type" => type} = data}, type), do: {:ok, data}

  defp fetch_data(%{"data" => %{"type" => _other}}, type),
    do: {:error, 409, "Conflict", "type must be #{type}", "/data/type"}

  defp fetch_data(_params, _type),
    do: {:error, 400, "Bad Request", "data with a type is required", "/data"}

  defp scope(%{"relationships" => relationships}), do: target(relationships)
  defp scope(_data), do: {:ok, :all}

  defp target(%{"target" => %{"data" => %{"type" => type, "id" => id}}})
       when is_map_key(@target_types, type) and is_binary(id),
       do: {:ok, {Map.fetch!(@target_types, type), id}}

  defp target(%{"target" => %{"data" => _data}}),
    do:
      {:error, 400, "Bad Request", "target must be a parameter or a stage",
       "/data/relationships/target/data"}

  defp target(%{"target" => _target}),
    do: {:error, 400, "Bad Request", "target must hold data", "/data/relationships/target"}

  defp target(_relationships),
    do: {:error, 400, "Bad Request", "relationships must hold a target", "/data/relationships"}

  defp not_found({:group, id}), do: "no stage #{id}"
  defp not_found({:parameter, id}), do: "no parameter #{id}"
end
