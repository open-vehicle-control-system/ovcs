defmodule VisionCore.Config do
  @moduledoc """
  A vehicle's vision configuration, returned by its
  `c:VisionCore.Composer.config/1` callback.

    * `:zenoh_endpoint_ip` — the Zenoh router the pipeline peers with.
    * `:components` — the pipeline's components on top of the always-on
      `VisionCore.Ros2.ZenohClient` and `VisionCore.Ros2.Parameters`. Each entry is
      a bare component atom (`:heartbeat`) or a `{name, opts}` tuple. See
      `VisionCore.Components` for the catalogue.
    * `:node_name` — the ROS 2 node name announced in the rmw_zenoh
      liveliness tokens. Defaults to `VisionCore.Ros2.ZenohClient`'s default.
      Set it whenever another ROS 2 node on the same fabric could share
      the name: two nodes with one name collide in the ROS graph.
    * `:preview` — options of `VisionCore.Preview` (`:max_hz`,
      `:depth_range_m`).
  """
  @enforce_keys [:zenoh_endpoint_ip]
  defstruct [:zenoh_endpoint_ip, :node_name, components: [], preview: []]

  @type component :: atom() | {atom(), keyword()}
  @type t :: %__MODULE__{
          zenoh_endpoint_ip: String.t(),
          node_name: String.t() | nil,
          components: [component()],
          preview: keyword()
        }
end

defmodule VisionCore do
  @moduledoc """
  Stereo depth and object detection published over native Zenoh as ROS 2
  messages. It carries no vehicle knowledge: the vehicle package names the
  cameras, calibration, tuning and detector through a
  `VisionCore.Composer`.

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
end
