defmodule VisionApiWeb.StagePresenter do
  @moduledoc """
  A `VisionCore.Parameters.Group` as a `stages` JSON:API resource. Its
  `role` is `source` for a component in the pipeline flow, `step` for a
  pipeline stage in it, `branch` for anything beside it.
  """
  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters.Group

  @spec present(Group.t()) :: map()
  def present(%Group{} = group) do
    JsonApi.resource(
      "stages",
      group.id,
      %{
        name: group.name,
        summary: group.summary,
        role: role(group),
        position: group.position,
        status: status(group.status),
        compute: group.compute
      },
      %{parameters: JsonApi.to_many("parameters", Enum.map(group.parameters, & &1.id))}
    )
  end

  defp role(%Group{placement: :side}), do: "branch"
  defp role(%Group{kind: :component}), do: "source"
  defp role(%Group{kind: :stage}), do: "step"

  defp status(nil), do: nil
  defp status({level, detail}), do: %{level: level, detail: detail}
end
