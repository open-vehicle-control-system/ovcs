defmodule VisionApiWeb.ParameterJSON do
  @moduledoc "The JSON:API resource objects of `parameters` and `parameter-groups`."
  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters.{Group, Parameter}

  @spec parameter(Parameter.t()) :: map()
  def parameter(%Parameter{} = parameter) do
    JsonApi.resource(
      "parameters",
      parameter.id,
      %{
        name: parameter.name,
        type: parameter.type,
        constraint: constraint(parameter.constraint),
        applies: applies(parameter.applies),
        description: parameter.description,
        default: parameter.default,
        value: parameter.value,
        saved: parameter.saved,
        state: parameter.state
      },
      %{
        group: to_one("parameter-groups", parameter.group),
        controller: to_one("parameters", controller(parameter.applies)),
        "greater-than": to_one("parameters", parameter.greater_than)
      }
    )
  end

  @doc "The parameters of `groups`, in order."
  @spec parameters([Group.t()]) :: [Parameter.t()]
  def parameters(groups), do: Enum.flat_map(groups, & &1.parameters)

  @spec group(Group.t()) :: map()
  def group(%Group{} = group) do
    JsonApi.resource(
      "parameter-groups",
      group.id,
      %{
        name: group.name,
        summary: group.summary,
        kind: group.kind,
        placement: group.placement,
        position: group.position,
        status: status(group.status)
      },
      %{
        parameters: %{
          data: Enum.map(group.parameters, &%{type: "parameters", id: &1.id})
        }
      }
    )
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

  defp status(nil), do: nil
  defp status({level, detail}), do: %{level: level, detail: detail}

  defp to_one(_type, nil), do: %{data: nil}
  defp to_one(type, id), do: %{data: %{type: type, id: id}}
end
