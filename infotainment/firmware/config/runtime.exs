import Config

case OvcsVehicle.Firmware.resolve_side(
       :infotainment,
       __DIR__,
       config_env(),
       Application.compile_env(:infotainment_firmware, :vehicle)
     ) do
  nil ->
    :ok

  {vehicle, infotainment} ->
    config :infotainment_core, :vehicle, infotainment
    config :ovcs_vehicle, :module, vehicle

    default_can_environment =
      Application.compile_env(:infotainment_firmware, :default_can_environment, :host)

    config :cantastic,
      can_network_mappings: fn ->
        (System.get_env("CAN_NETWORK_MAPPINGS") ||
           infotainment.default_can_mapping(default_can_environment))
        |> String.split(",", trim: true)
        |> Enum.map(fn i ->
          [network_name, can_interface] = i |> String.split(":", trim: true)
          {network_name, can_interface}
        end)
      end,
      otp_app: vehicle.can_config_otp_app(),
      priv_can_config_path: infotainment.can_config_path()

    # See `vms/firmware/config/runtime.exs` for the rationale.
    if Application.spec(:nerves_ssh, :vsn) do
      if dir = OvcsVehicle.Firmware.ssh_system_dir(vehicle, "infotainment") do
        config :nerves_ssh, system_dir: String.to_charlist(dir)
      end
    end
end

if System.get_env("PHX_SERVER") do
  config :infotainment_api, InfotainmentApiWeb.Endpoint, server: true
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

  config :infotainment_api, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :infotainment_api, InfotainmentApiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
