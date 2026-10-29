defmodule VisionApiWeb.ParametersController do
  @moduledoc """
  The vision core's ROS 2 parameters (`VisionCore.Ros2.Parameters`):
  listed with their values and constraints, and set one at a time as a
  ROS set request would.
  """
  use VisionApiWeb, :controller

  alias VisionCore.Ros2.Parameters

  def index(conn, _params),
    do: json(conn, %{parameters: Enum.map(Parameters.list(), &encode/1)})

  def update(conn, %{"name" => name, "value" => value}) do
    case Parameters.set_value(name, value) do
      {:ok, value} ->
        json(conn, %{name: name, value: value})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  defp encode(parameter) do
    parameter
    |> Map.put_new(:read_only, false)
    |> Map.update(:range, nil, &Tuple.to_list/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
