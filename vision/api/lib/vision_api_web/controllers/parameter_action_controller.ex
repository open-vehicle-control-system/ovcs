defmodule VisionApiWeb.ParameterActionController do
  @moduledoc """
  Save, discard and reset of the vision parameters, created as action
  resources, and the read-only export.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters

  @target_types %{"parameter-groups" => :group, "parameters" => :parameter}

  def save(conn, params) do
    act(conn, params, "parameter-saves", fn _data ->
      case Parameters.save() do
        {:ok, ids} -> {:ok, ids}
        {:error, reason} -> {:error, 503, "Saved values unavailable", reason, nil}
      end
    end)
  end

  def discard(conn, params) do
    act(conn, params, "parameter-discards", fn _data -> Parameters.discard() end)
  end

  def reset(conn, params) do
    act(conn, params, "parameter-resets", fn data ->
      with {:ok, scope} <- scope(data),
           :ok <- check_scope(scope) do
        case Parameters.reset(scope) do
          {:ok, ids} -> {:ok, ids}
          {:error, reason} -> {:error, 422, "Not reset", reason, nil}
        end
      end
    end)
  end

  def export(conn, _params) do
    JsonApi.send_document(conn, 200, %{
      data: %{
        type: "parameter-exports",
        id: "current",
        attributes: %{snippet: Parameters.export()}
      }
    })
  end

  defp act(conn, params, type, run) do
    with {:ok, data} <- fetch_data(params, type),
         {:ok, ids} <- run.(data) do
      id = Integer.to_string(System.unique_integer([:positive, :monotonic]))
      JsonApi.send_document(conn, 201, %{data: JsonApi.action(type, id, ids)})
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

  defp scope(%{"relationships" => %{"target" => %{"data" => target}}}) do
    case target do
      %{"type" => type, "id" => id} when is_map_key(@target_types, type) and is_binary(id) ->
        {:ok, {Map.fetch!(@target_types, type), id}}

      _target ->
        {:error, 400, "Bad Request", "target must be a parameter or a parameter group",
         "/data/relationships/target/data"}
    end
  end

  defp scope(_data), do: {:ok, :all}

  defp check_scope(:all), do: :ok

  defp check_scope({:group, id}) do
    if Enum.any?(Parameters.groups(), &(&1.id == id)),
      do: :ok,
      else: {:error, 404, "Not Found", "no parameter group #{id}", nil}
  end

  defp check_scope({:parameter, id}) do
    case Parameters.get(id) do
      {:ok, _parameter} -> :ok
      {:error, :not_found} -> {:error, 404, "Not Found", "no parameter #{id}", nil}
    end
  end
end
