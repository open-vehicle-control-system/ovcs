import Config

# `resolve_side/4` reads VEHICLE, prepends the vehicle's compiled
# ebin, and hands back `{vehicle, composer}`. `nil` means no VEHICLE
# (or `MIX_ENV=test`); skip Cantastic wiring in that case.
case OvcsVehicle.Firmware.resolve_side(
       :vms,
       __DIR__,
       config_env(),
       Application.compile_env(:vms_firmware, :vehicle)
     ) do
  nil ->
    :ok

  {vehicle, vms} ->
    config :vms_core, :vehicle, vms
    config :ovcs_vehicle, :module, vehicle

    config :cantastic,
      can_network_mappings: {
        VmsFirmware.Util.NetworkMapper,
        :can_network_mappings,
        [System.get_env("CAN_NETWORK_MAPPINGS") || vms.default_can_mapping(:host)]
      },
      otp_app: vehicle.can_config_otp_app(),
      priv_can_config_path: vms.can_config_path()

    # Stable SSH host keys baked into the vehicle's priv (generated
    # by `./ovcs vehicle host-keys`). When absent, NervesSSH falls
    # back to its default /data path and regenerates on each fresh
    # burn (the legacy behaviour). Skip entirely on host builds where
    # `:nerves_ssh` isn't a dep.
    if Application.spec(:nerves_ssh, :vsn) do
      if dir = OvcsVehicle.Firmware.ssh_system_dir(vehicle, "vms") do
        config :nerves_ssh, system_dir: String.to_charlist(dir)
      end
    end
end

# Phoenix endpoint opt-in for release builds (matches the original
# `vms/api` runtime.exs guidance).
if System.get_env("PHX_SERVER") do
  config :vms_api, VmsApiWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :vms_api, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :vms_api, VmsApiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
