defmodule OvcsBridge.Supervisor do
  @moduledoc """
  Root supervisor for an OVCS bridge firmware image.

  Parameters are pulled from the `:ovcs_bridge` application
  environment (the bridges firmware sets them from `VEHICLE` +
  `BRIDGE_FIRMWARE_ID` at compile time):

      config :ovcs_bridge,
        vehicle: "Ovcs1",
        firmware_id: "radio_control"

  At boot the supervisor:
    * looks up the entry in the vehicle's `bridge_firmwares/0` map;
    * collects `children/0` from every bundled bridge module listed
      in that entry;
    * optionally starts `OvcsBus.Mqtt.Relay` when the entry has a
      `:bus_relay` key.

  The firmware's `Application` becomes a thin wrapper that just
  starts this supervisor — symmetrical to how `vms_core` and
  `infotainment_core` own the supervision tree on their sides.
  """
  use Supervisor
  require Logger

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    entry = resolve_entry!()

    bridges = Map.get(entry, :bridges, [])
    bridge_children = Enum.flat_map(bridges, & &1.children())
    relay_children = relay_children(entry, bridges)

    Logger.info(
      "OvcsBridge.Supervisor starting #{vehicle_name()}/#{firmware_id()} " <>
        "with #{length(bridge_children)} bridge child(ren)" <>
        if(relay_children == [], do: "", else: " + MQTT relay")
    )

    Supervisor.init(bridge_children ++ relay_children, strategy: :one_for_one)
  end

  # Start at most one relay per firmware. Broker/identity come from
  # the vehicle (`bus_relay` in the entry); message names come from
  # each bundled bridge's `relay_messages/0` (unioned, deduped).
  # Vehicle can override by passing :topics explicitly in :bus_relay.
  defp relay_children(entry, bridges) do
    case Map.get(entry, :bus_relay) do
      nil ->
        []

      broker_opts ->
        opts = normalize(broker_opts)

        topics =
          case Keyword.get(opts, :topics) do
            nil -> collect_bridge_messages(bridges)
            explicit -> explicit
          end

        if topics == [] do
          []
        else
          [{OvcsBus.Mqtt.Relay, Keyword.put(opts, :topics, topics)}]
        end
    end
  end

  defp normalize(%{} = opts), do: Enum.to_list(opts)
  defp normalize(opts) when is_list(opts), do: opts

  defp collect_bridge_messages(bridges) do
    bridges
    |> Enum.flat_map(fn bridge ->
      if function_exported?(bridge, :relay_messages, 0), do: bridge.relay_messages(), else: []
    end)
    |> Enum.uniq()
  end

  defp resolve_entry! do
    vehicle = vehicle_module()
    id = firmware_id()

    case Map.fetch(vehicle.bridge_firmwares(), id) do
      {:ok, entry} ->
        entry

      :error ->
        raise """
        OvcsBridge.Supervisor: no entry #{inspect(id)} in #{inspect(vehicle)}.bridge_firmwares/0.
        Known ids: #{Map.keys(vehicle.bridge_firmwares()) |> Enum.join(", ")}
        """
    end
  end

  defp vehicle_module do
    name = vehicle_name() || raise "OvcsBridge: :vehicle not set in app env (set VEHICLE at build time)"
    Module.concat([name])
  end

  defp vehicle_name, do: Application.get_env(:ovcs_bridge, :vehicle)

  defp firmware_id do
    Application.get_env(:ovcs_bridge, :firmware_id) ||
      raise "OvcsBridge: :firmware_id not set in app env (set BRIDGE_FIRMWARE_ID at build time)"
  end
end
