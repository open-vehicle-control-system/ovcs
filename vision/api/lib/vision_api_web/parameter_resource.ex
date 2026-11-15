defmodule VisionApiWeb.ParameterResource do
  @moduledoc """
  A `VisionCore.Parameters.Parameter` as a `parameters` JSON:API
  resource object, and the `meta` of a document about parameters, as
  the `parameters` and `stages` resources carry them.
  """
  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters.{Group, Parameter}

  @doc "The `parameters` resource of `parameter`, related to its `stage`, `controlledBy` and `greaterThan` parameters."
  @spec object(Parameter.t()) :: map()
  def object(%Parameter{} = parameter) do
    JsonApi.resource(
      "parameters",
      parameter.id,
      %{
        name: parameter.name,
        valueType: parameter.type,
        constraint: constraint(parameter.constraint),
        applies: applies(parameter.applies),
        description: parameter.description,
        default: parameter.default,
        value: parameter.value,
        saved: parameter.saved,
        state: parameter.state
      },
      %{
        stage: JsonApi.to_one("stages", parameter.group),
        controlledBy: JsonApi.to_one("parameters", controller(parameter.applies)),
        greaterThan: JsonApi.to_one("parameters", parameter.greater_than)
      }
    )
  end

  @doc "The document `meta` of a response about `groups`: how many parameters are unsaved."
  @spec meta([Group.t()]) :: map()
  def meta(groups) do
    unsaved = groups |> Enum.flat_map(& &1.parameters) |> Enum.count(&(&1.state == :unsaved))
    %{unsaved: unsaved}
  end

  defp constraint(nil), do: nil

  defp constraint(%{kind: :range} = range),
    do: %{kind: :range, min: range.min, max: range.max, step: Map.get(range, :step)}

  defp constraint(%{kind: :choices} = choices), do: Map.take(choices, [:kind, :values])
  defp constraint(%{kind: :bool}), do: %{kind: :bool}

  defp applies(:build), do: "build"
  defp applies(_live_or_auto), do: "live"

  defp controller({:auto, controller}), do: controller
  defp controller(_applies), do: nil
end
