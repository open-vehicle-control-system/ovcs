defmodule OvcsBridge.Supervisor do
  @moduledoc """
  Root supervisor for an OVCS bridge firmware image.

  Parameters come from the `VEHICLE` / `BRIDGE_FIRMWARE_ID` env vars when
  set (each BEAM `./ovcs run` launches gets its own), falling back to the
  `:ovcs_bridge` application environment baked at compile time:

      config :ovcs_bridge,
        vehicle: "Ovcs1",
        firmware_id: "radio_control"

  The env-first order matters on host dev, where every bridge role shares
  one compiled build — the baked `:firmware_id` would otherwise make all
  bridge BEAMs run the same bridge.

  At boot the supervisor:
    * looks up the entry in the vehicle's `bridge_firmwares/0` map;
    * supervises `OvcsBus.Cluster` so this BEAM joins the vehicle's
      distributed-Erlang mesh;
    * ensures each bundled bridge's OTP application is started
      (no-op on target builds, explicit on host dev where bridges
      are `runtime: false`);
    * collects `children/0` from every bundled bridge module listed
      in that entry.

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

    # Start each bundled bridge's own OTP application (and its transitive
    # deps) before touching `children/0`. On target builds this is a no-op
    # — bridges/firmware pulls only the bridge matching `MIX_TARGET`, and
    # OTP has already auto-started it by the time we get here. On host
    # dev bridges/firmware pulls every bridge lib at once and declares
    # them `runtime: false` so OTP does NOT auto-start them; otherwise
    # the inactive bridge's Application (e.g. `ExpressLrs.Application`'s
    # Mavlink Parser) would run inside the wrong BEAM and spam unrelated
    # logs. Ensuring the active bridge's app here keeps the active
    # BEAM's supervision stack identical to what it'd be on target.
    Enum.each(bridges, &ensure_bridge_started/1)

    bridge_children = Enum.flat_map(bridges, & &1.children())
    cluster_children = cluster_child()

    Logger.info(
      "OvcsBridge.Supervisor starting #{vehicle_name()}/#{firmware_id()} " <>
        "with #{length(bridge_children)} bridge child(ren)"
    )

    Supervisor.init(cluster_children ++ bridge_children, strategy: :one_for_one)
  end

  defp cluster_child do
    case Application.get_env(:ovcs_vehicle, :module) do
      nil -> []
      mod -> [{OvcsBus.Cluster, vehicle: mod}]
    end
  end

  defp ensure_bridge_started(bridge_module) do
    _ = Code.ensure_loaded(bridge_module)

    case Application.get_application(bridge_module) do
      nil ->
        Logger.warning(
          "OvcsBridge.Supervisor: #{inspect(bridge_module)} has no OTP application; " <>
            "skipping auto-start"
        )

      app ->
        case Application.ensure_all_started(app) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "OvcsBridge.Supervisor: failed to start #{app}: #{inspect(reason)}"
            )
        end
    end
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
    name = vehicle_name() || raise "OvcsBridge: :vehicle not set (set VEHICLE at build/run time)"
    Module.concat([name])
  end

  # On host (`./ovcs run`) every bridge role shares one compiled
  # bridges/firmware build, so the compile-time `:vehicle` / `:firmware_id`
  # are whatever VEHICLE / BRIDGE_FIRMWARE_ID happened to be set to at build
  # time (the build.sh host defaults). Each BEAM is launched with its own
  # env, so prefer that — otherwise both bridge BEAMs would run the same
  # bridge. On target the env isn't present at runtime, so we fall back to
  # the value baked per-firmware at build time. Mirrors config/runtime.exs.
  defp vehicle_name do
    System.get_env("VEHICLE") || Application.get_env(:ovcs_bridge, :vehicle)
  end

  defp firmware_id do
    System.get_env("BRIDGE_FIRMWARE_ID") ||
      Application.get_env(:ovcs_bridge, :firmware_id) ||
      raise "OvcsBridge: firmware id not set (set BRIDGE_FIRMWARE_ID env or :ovcs_bridge :firmware_id)"
  end
end
