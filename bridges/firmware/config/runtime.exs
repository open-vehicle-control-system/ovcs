import Config

case OvcsVehicle.Firmware.resolve_bridge(
       __DIR__,
       config_env(),
       System.get_env("BRIDGE_FIRMWARE_ID") ||
         Application.compile_env(:ovcs_bridge, :firmware_id),
       System.get_env("VEHICLE") ||
         Application.compile_env(:ovcs_bridge, :vehicle)
     ) do
  nil ->
    :ok

  {vehicle, bridge_firmware_id, entry} ->
    config :ovcs_vehicle, :module, vehicle

    mapping_string =
      System.get_env("CAN_NETWORK_MAPPINGS") ||
        (entry[:default_can_mapping] || %{target: ""})
        |> Map.get(:target, "")

    config :cantastic,
      can_network_mappings: {
        BridgeFirmware.Util.NetworkMapper,
        :can_network_mappings,
        [mapping_string]
      }

    # Vehicle may override the per-bridge YAML path; otherwise follow
    # the convention `can/bridges/<id>.yml`. Runtime.exs runs after
    # host.exs / target.exs, so this is the single source of truth.
    priv_path = entry[:can_config_path] || "can/bridges/#{bridge_firmware_id}.yml"
    config :cantastic, priv_can_config_path: priv_path

    # If this firmware bundles RadioControlBridge, wire express_lrs's
    # UART connector from the `:mavlink_forwarder` component's opts.
    # ExpressLrs.Application reads `:enabled` + `:interface` once at
    # boot, so the config has to land here in runtime.exs (before
    # applications start) rather than in the bridge's children/0.
    # UART pins live with the component that uses them — the MSP
    # DisplayPort path will eventually have its own UART under
    # `:msp_osd_forwarder` opts, talking to a different serial line.
    # `build_target` was captured from `Mix.target()` in config.exs
    # so the vehicle picks the right arm of `radio_control_bridge_config/1`.
    if Code.ensure_loaded?(RadioControlBridge) and
         RadioControlBridge in (entry[:bridges] || []) do
      build_target = Application.compile_env(:ovcs_bridge, :build_target, :host)
      cfg = vehicle.radio_control_bridge_config(build_target)

      case RadioControlBridge.Config.component_opts(cfg, :mavlink_forwarder) do
        nil ->
          :ok

        opts ->
          config :express_lrs,
            enabled: true,
            interface: %{
              uart_port: Keyword.fetch!(opts, :uart_port),
              uart_baud_rate: Keyword.fetch!(opts, :uart_baud_rate)
            }
      end
    end

    # See `vms/firmware/config/runtime.exs` for the rationale.
    if Application.spec(:nerves_ssh, :vsn) do
      if dir = OvcsVehicle.Firmware.ssh_system_dir(vehicle, "bridges/#{bridge_firmware_id}") do
        config :nerves_ssh, system_dir: String.to_charlist(dir)
      end
    end
end
