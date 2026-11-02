defmodule VisionApiWeb.StagePresenter do
  @moduledoc """
  A `VisionCore.Parameters.Group` as a `stages` JSON:API resource. Its
  `pipeline` is the pipeline it is part of, such as `stereo` or `detection`,
  and its `role` there `source` for a component, `step` for a stage.
  """
  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters.Group

  @doc "The `stages` resource of `group`, related to its parameters."
  @spec present(Group.t()) :: map()
  def present(%Group{} = group) do
    JsonApi.resource(
      "stages",
      group.id,
      %{
        name: group.name,
        summary: group.summary,
        explanation: group.explanation,
        pipeline: group.pipeline,
        role: role(group),
        position: group.position,
        status: status(group.status),
        compute: compute(group.compute)
      },
      %{parameters: JsonApi.to_many("parameters", Enum.map(group.parameters, & &1.id))}
    )
  end

  defp role(%Group{kind: :component}), do: "source"
  defp role(%Group{kind: :stage}), do: "step"

  defp compute(nil), do: nil

  defp compute(compute),
    do: %{
      runsOn: compute.runs_on,
      implementation: compute.implementation,
      backend: compute.backend
    }

  defp status(nil), do: nil
  defp status({level, detail}), do: %{level: level, detail: detail}
end
