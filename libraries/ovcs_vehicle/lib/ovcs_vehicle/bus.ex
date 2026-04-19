defmodule OvcsVehicle.Bus do
  @moduledoc """
  Helpers for declaring `OvcsBus.Mqtt.Relay` opts from a vehicle
  package.

  Each vehicle has a single topic prefix (`"ovcs/<name>/bus"`) and a
  single broker host that differs between host dev (`localhost`) and
  deployed Nerves (`<vehicle>-vms.local`). Rather than restate the
  `broker`/`topic_prefix` tuple in each VMS composer, infotainment
  composer, and bridge entry, call `relay_opts/3` with the role's
  client_id + any extras (`:topics`, custom opts).

  ## Contract on the vehicle module

  * `broker_host/0` — **required**; typically

        @broker_host (if Mix.target() == :host, do: "localhost", else: "<dir>-vms.local")
        def broker_host, do: @broker_host

  * `broker_port/0` — optional, defaults to 1884 (Mosquitto listener).
  * `topic_prefix/0` — optional, defaults to `"ovcs/<snake_name>/bus"`
    derived from the module name.
  """

  @default_port 1884

  @doc """
  Build the base `OvcsBus.Mqtt.Relay` opts map for a role on `vehicle`.

  `extras` is any enumerable of `{key, value}` pairs (typically a
  keyword list or a map); it's merged over the base, so callers can
  override any of the defaults and add role-specific keys such as
  `:topics`.
  """
  @spec relay_opts(module(), String.t(), Enum.t()) :: map()
  def relay_opts(vehicle, client_id, extras \\ []) do
    Map.merge(
      %{
        broker: [host: vehicle.broker_host(), port: broker_port(vehicle)],
        client_id: client_id,
        topic_prefix: topic_prefix(vehicle)
      },
      Map.new(extras)
    )
  end

  @doc "Port of the vehicle's MQTT broker. Defaults to 1884."
  @spec broker_port(module()) :: pos_integer()
  def broker_port(vehicle) do
    if function_exported?(vehicle, :broker_port, 0),
      do: vehicle.broker_port(),
      else: @default_port
  end

  @doc "Topic prefix for this vehicle's bus. Defaults to `ovcs/<name>/bus`."
  @spec topic_prefix(module()) :: String.t()
  def topic_prefix(vehicle) do
    if function_exported?(vehicle, :topic_prefix, 0),
      do: vehicle.topic_prefix(),
      else: "ovcs/#{default_dir(vehicle)}/bus"
  end

  defp default_dir(vehicle) do
    vehicle |> Module.split() |> List.last() |> Macro.underscore()
  end
end
