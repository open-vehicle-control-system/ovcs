defmodule VisionCore.Config do
  @moduledoc """
  A vehicle's vision configuration, returned by its
  `c:VisionCore.Composer.config/1` callback.

    * `:components` — what produces the unit's outputs: the stereo unit
      and the detector. Each entry is a bare component atom or a
      `{name, opts}` tuple; see `VisionCore.Components` for the
      catalogue.
    * `:exporters` — what takes the outputs out of the unit, each
      `{module, options}`, or a module alone for `{module, []}`, `module`
      implementing `VisionCore.Exporter`, such as
      `VisionCore.Ros2.Exporter`; see `VisionCore.Exporters`.
    * `:ros2` — the ROS 2 link, on top of the always-on
      `VisionCore.Parameters`: the Zenoh session the ROS 2 exporter
      publishes through and a `VisionCore.Ros2.Camera` reads from, the
      parameters as ROS 2 parameter services, and the published topics'
      counts. Without it, no ROS 2 process starts. Options:
        * `:zenoh_endpoint_ip` (required) — the Zenoh router the unit
          peers with.
        * `:node_name` (`"ovcs_vision"`) — the ROS 2 node name announced
          in the rmw_zenoh liveliness tokens. Set it whenever another ROS 2
          node on the same fabric could share the name: two nodes with
          one name collide in the ROS graph.
        * `:domain_id` (`0`) — the ROS 2 domain.
        * `:simulator_clock` — `true`, or `VisionCore.Ros2.Clock`'s
          options, to stamp with the simulator's `/clock` rather than
          wall clock. **Simulation only**: see `VisionCore.Ros2.Clock`
          for what wall clock breaks against a simulator.
    * `:preview` — options of `VisionCore.Preview` (`:max_hz`,
      `:depth_range_m`, `:outputs`).
    * `:jpeg` — options of `VisionCore.Jpeg.Export`, the pool of
      `jpeg_codec` Ports the previews and exporters encode on:
        * `:ports` (`3`) — the most Ports encoding at once, a positive
          integer. Each runs one encode at a time, so it bounds the
          encodes, their memory and the CPU cores they take.
  """
  defstruct ros2: nil, components: [], exporters: [], preview: [], jpeg: []

  @type component :: atom() | {atom(), keyword()}
  @type t :: %__MODULE__{
          ros2: keyword() | nil,
          components: [component()],
          exporters: [{module(), keyword()} | module()],
          preview: keyword(),
          jpeg: keyword()
        }
end

defmodule VisionCore do
  @moduledoc """
  Stereo depth and object detection, taken out of the unit by its
  exporters, such as ROS 2 messages over native Zenoh. It carries no
  vehicle knowledge: the vehicle package names the cameras, calibration,
  tuning, detector and exporters through a `VisionCore.Composer`.

  `VisionCore.Application` starts the pipeline under `VisionCore.Supervisor`
  when `:vision_core, :vehicle` names a composer.
  """

  # Read at compile time: on a Nerves device `Mix.target()` returns
  # `:host` at runtime, which would pick the wrong config arm.
  @arm if Mix.target() == :host, do: :host, else: :target

  @doc "The config arm this build runs as, `:host` or `:target`."
  @spec arm() :: :host | :target
  def arm, do: @arm

  @doc """
  The `VisionCore.Config` the pipeline started with, as plain
  JSON-encodable terms: structs and keyword lists become maps, tuples
  lists, modules their name. `%{}` when no pipeline runs.
  """
  @spec settings() :: map()
  def settings do
    case VisionCore.Application.active_config() do
      nil -> %{}
      config -> settings_term(config)
    end
  end

  defp settings_term(%VisionCore.Config{} = config) do
    config
    |> Map.from_struct()
    |> Map.update!(:components, fn components -> Enum.map(components, &component_term/1) end)
    |> Map.update!(:exporters, fn exporters -> Enum.map(exporters, &exporter_term/1) end)
    |> settings_term()
  end

  defp settings_term(%_{} = struct), do: struct |> Map.from_struct() |> settings_term()

  defp settings_term(map) when is_map(map),
    do: Map.new(map, fn {key, term} -> {settings_key(key), settings_term(term)} end)

  defp settings_term(list) when is_list(list) do
    if list != [] and Keyword.keyword?(list),
      do: list |> Map.new() |> settings_term(),
      else: Enum.map(list, &settings_term/1)
  end

  defp settings_term(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> settings_term()
  defp settings_term(term) when is_boolean(term) or is_nil(term), do: term
  defp settings_term(atom) when is_atom(atom), do: settings_key(atom)
  defp settings_term(term) when is_number(term) or is_binary(term), do: term
  defp settings_term(term), do: inspect(term)

  defp settings_key(key) when is_atom(key) do
    name = Atom.to_string(key)
    if String.starts_with?(name, "Elixir."), do: inspect(key), else: name
  end

  defp settings_key(key) when is_binary(key), do: key
  defp settings_key(key), do: inspect(key)

  defp component_term({name, options}), do: %{name: name, options: options}
  defp component_term(name), do: %{name: name, options: []}

  defp exporter_term({module, options}), do: %{module: module, options: options}
  defp exporter_term(module), do: %{module: module, options: []}
end
