defmodule VisionCore.Detection do
  @moduledoc """
  The names of the detection pipelines a unit runs.

  Each `:detector` component (`VisionCore.Components`) starts one
  pipeline under its own `VisionCore.Detection.Supervisor`, named by its
  `:name` option, `:detection` without one. The name keys the pipeline's
  processes (`server/2`), its `VisionCore.Outputs` key, its parameter
  groups (`<name>.*`), its exporters' outputs and its ROS 2 topics
  (`<prefix>/<name>/…`). The default pipeline, `:detection`, keeps its
  processes registered under their modules.

  A name is a ROS 2 parameter name segment, so it holds no `.` or `-`,
  and is none of the reserved names: `:stereo`, the stereo pipeline's;
  `:left`, `:right`, `:depth`, `:disparity`, `:points`, `:detections`
  and `:live`, the first segments of the topics the ROS 2 exporter
  publishes under `<prefix>/`; and `:device`, whose Hailo backend
  process would take the name of the Hailo-8 claim
  (`VisionCore.Detection.Backend.Hailo.Device`).
  """

  @default_name :detection
  @name_pattern ~r/^[a-z][a-z0-9_]*$/
  @reserved_names [
    :stereo,
    :left,
    :right,
    :depth,
    :disparity,
    :points,
    :detections,
    :live,
    :device
  ]

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

  @doc """
  Whether `name` is a valid pipeline name: an atom matching
  `^[a-z][a-z0-9_]*$`, none of the reserved names (see the module doc).
  """
  @spec name?(term()) :: boolean()
  def name?(name),
    do:
      is_atom(name) and name not in [nil, true, false | @reserved_names] and
        Regex.match?(@name_pattern, Atom.to_string(name))

  @doc """
  `name` when it is a valid pipeline name (`name?/1`). Raises
  `ArgumentError` stating the rule for `owner`'s name otherwise: a camera
  (`VisionCore.Camera.Unit`) follows the same rule.
  """
  @spec name!(term(), String.t()) :: atom()
  def name!(name, owner \\ "a detection pipeline") do
    if name?(name),
      do: name,
      else:
        raise(
          ArgumentError,
          "#{owner}'s name is an atom matching ^[a-z][a-z0-9_]*$, " <>
            "not one of #{Enum.map_join(@reserved_names, ", ", &inspect/1)}, got #{inspect(name)}"
        )
  end
end
