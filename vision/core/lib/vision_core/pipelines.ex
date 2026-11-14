defmodule VisionCore.Pipelines do
  @moduledoc """
  The names of the pipelines a unit runs and of the cameras of its own,
  and of the processes that serve each.

  A detection pipeline (`VisionCore.Detection`), a segmentation pipeline
  (`VisionCore.Segmentation`) and a camera of its own
  (`VisionCore.Camera.Unit`) are each named by their `:name` option. The
  name keys the unit's processes (`server/2`), its `VisionCore.Outputs`
  key, its parameter groups (`<name>.*`, a camera's `<name>.camera`), its
  exporters' outputs and its
  ROS 2 topics (`<name>/…`), so no two of them share one
  (`VisionCore.Application`).

  A name is a ROS 2 parameter name segment, so it holds no `.` or `-`,
  and is none of the reserved names: `:stereo`, the stereo pipeline's and
  its topics' default namespace; `:left`, `:right`, `:depth`,
  `:disparity` and `:points`, the first segments of the stereo unit's
  topics, which a camera or pipeline whose exporter gives it the stereo
  unit's prefix as its `:topic_prefix` would publish among.
  """

  @name_pattern ~r/^[a-z][a-z0-9_]*$/
  @reserved_names [
    :stereo,
    :left,
    :right,
    :depth,
    :disparity,
    :points
  ]

  @doc """
  The name `module`'s process of the pipeline `name` is registered
  under, in `VisionCore.Processes`: what to start it under and to call
  it by, and `GenServer.whereis/1` gives its pid.

      GenServer.whereis(Pipelines.server(VisionCore.Detection.Pipeline, :road_signs))
  """
  @spec server(module(), atom()) :: GenServer.name()
  defdelegate server(module, name), to: VisionCore.Processes, as: :via

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
