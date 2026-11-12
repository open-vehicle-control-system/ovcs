defmodule VisionCore.Detection do
  @moduledoc """
  The detection pipelines a unit runs.

  Each `:detector` component (`VisionCore.Components`) starts one
  pipeline under its own `VisionCore.Detection.Supervisor`, named by its
  `:name` option, `:detection` without one (`VisionCore.Pipelines`). The
  default pipeline, `:detection`, keeps its processes registered under
  their modules, and its exporters' output is `:detections`.
  """

  @default_name :detection

  @doc "The pipeline name a detector's `opts` give: their `:name`, `:detection` without one."
  @spec pipeline_name(keyword()) :: atom()
  def pipeline_name(opts), do: Keyword.get(opts, :name, @default_name)

  @doc """
  The `VisionCore.Exporter` output of the pipeline `name`'s detections:
  `:detections` for the default pipeline, `{:detections, name}` otherwise.
  """
  @spec output(atom()) :: :detections | {:detections, atom()}
  def output(@default_name), do: :detections
  def output(name), do: {:detections, name}
end
