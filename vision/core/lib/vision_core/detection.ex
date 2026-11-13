defmodule VisionCore.Detection do
  @moduledoc """
  The detection pipelines a unit runs.

  Each `:detector` component (`VisionCore.Components`) starts one
  pipeline under its own `VisionCore.Detection.Supervisor`, named by its
  `:name` option, `:detection` without one (`VisionCore.Pipelines`).
  """

  @default_name :detection

  @doc "The pipeline name a detector's `opts` give: their `:name`, `:detection` without one."
  @spec pipeline_name(keyword()) :: atom()
  def pipeline_name(opts), do: Keyword.get(opts, :name, @default_name)

  @doc """
  The `VisionCore.Exporter` output of the pipeline `name`'s detections,
  `{:detections, name}`.
  """
  @spec output(atom()) :: {:detections, atom()}
  def output(name), do: {:detections, name}
end
