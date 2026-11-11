defmodule VisionCore.Detection do
  @moduledoc """
  The names of the detection pipelines a unit runs.

  Each `:detector` component (`VisionCore.Components`) starts one
  pipeline under its own `VisionCore.Detection.Supervisor`, named by its
  `:name` option, `:detection` without one. The name keys the pipeline's
  processes (`server/2`), its `VisionCore.Outputs` key, its parameter
  groups (`<name>.*`) and its exporters' outputs. The default pipeline,
  `:detection`, keeps its processes registered under their modules.

  A name is a ROS 2 parameter name segment, so it holds no `.` or `-`,
  and is not `:stereo`, the stereo pipeline's.
  """

  @default_name :detection
  @name_pattern ~r/^[a-z][a-z0-9_]*$/

  @doc """
  The name `module`'s process of the pipeline `name` is registered under:
  `module` itself for the default pipeline, `module` followed by the
  camelized name otherwise (`VisionCore.Detection.Pipeline.RoadSigns` for
  `:road_signs`).
  """
  @spec server(module(), atom()) :: module()
  def server(module, @default_name), do: module
  def server(module, name), do: Module.concat(module, Macro.camelize(Atom.to_string(name)))

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

  @doc "Whether `name` is a valid pipeline name: an atom matching `^[a-z][a-z0-9_]*$`, not `:stereo`."
  @spec name?(term()) :: boolean()
  def name?(name),
    do: is_atom(name) and name != :stereo and Regex.match?(@name_pattern, Atom.to_string(name))

  @doc """
  `name` when it is a valid pipeline name (`name?/1`). Raises
  `ArgumentError` stating the rule otherwise.
  """
  @spec name!(atom()) :: atom()
  def name!(name) do
    if name?(name),
      do: name,
      else:
        raise(
          ArgumentError,
          "a detection pipeline's name is an atom matching ^[a-z][a-z0-9_]*$, " <>
            "not :stereo, got #{inspect(name)}"
        )
  end
end
