defmodule VisionCore.Pipelines do
  @moduledoc """
  The names of the pipelines a unit runs and of the cameras of its own,
  and of the processes that serve each.

  A detection pipeline (`VisionCore.Detection`), a segmentation pipeline
  (`VisionCore.Segmentation`) and a camera of its own
  (`VisionCore.Camera.Unit`) are each named by their `:name` option. The
  name keys the unit's processes (`server/2`), its `VisionCore.Outputs`
  key, its parameter groups (`<name>.*`), its exporters' outputs and its
  ROS 2 topics (`<prefix>/<name>/…`), so no two of them share one
  (`VisionCore.Application`).

  A name is a ROS 2 parameter name segment, so it holds no `.` or `-`,
  and is none of the reserved names: `:stereo`, the stereo pipeline's;
  `:left`, `:right`, `:depth`, `:disparity`, `:points` and `:live`, the
  first segments of the topics the ROS 2 exporter publishes under
  `<prefix>/`; and `:device`, whose Hailo
  backend process would take the name of the Hailo-8 claim
  (`VisionCore.Detection.Backend.Hailo.Device`).
  """

  @name_pattern ~r/^[a-z][a-z0-9_]*$/
  @reserved_names [
    :stereo,
    :left,
    :right,
    :depth,
    :disparity,
    :points,
    :live,
    :device
  ]

  @doc """
  The name `module`'s process of the pipeline `name` is registered under:
  `module` followed by the camelized name
  (`VisionCore.Detection.Pipeline.RoadSigns` for `:road_signs`).
  """
  @spec server(module(), atom()) :: module()
  def server(module, name), do: Module.concat(module, Macro.camelize(Atom.to_string(name)))

  @doc """
  Whether `name` is a valid name: an atom matching `^[a-z][a-z0-9_]*$`,
  none of the reserved names (see the module doc).
  """
  @spec name?(term()) :: boolean()
  def name?(name),
    do:
      is_atom(name) and name not in [nil, true, false | @reserved_names] and
        Regex.match?(@name_pattern, Atom.to_string(name))

  @doc """
  `name` when it is a valid name (`name?/1`). Raises `ArgumentError`
  stating the rule for `owner`'s name otherwise.
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
