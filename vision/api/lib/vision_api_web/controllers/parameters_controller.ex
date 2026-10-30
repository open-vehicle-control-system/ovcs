defmodule VisionApiWeb.ParametersController do
  @moduledoc """
  The vision parameters (`VisionCore.Parameters`), listed with their values and
  constraints by id, and set one at a time as unsaved changes.
  """
  use VisionApiWeb, :controller

  alias VisionCore.Parameters

  def index(conn, _params) do
    parameters = Parameters.groups() |> Enum.flat_map(& &1.parameters) |> Enum.sort_by(& &1.id)
    json(conn, %{parameters: Enum.map(parameters, &encode/1)})
  end

  def update(conn, %{"name" => id, "value" => value}) do
    case Parameters.set(id, value) do
      {:ok, parameter} ->
        json(conn, %{name: id, value: parameter.value})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  defp encode(parameter) do
    %{
      name: parameter.id,
      type: parameter.type,
      value: parameter.value,
      read_only: parameter.applies == :build,
      description: parameter.description
    }
    |> Map.merge(constraint(parameter.constraint))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp constraint(%{kind: :range, min: min, max: max}), do: %{range: [min, max]}
  defp constraint(%{kind: :choices, values: values}), do: %{values: values}
  defp constraint(_constraint), do: %{}
end
