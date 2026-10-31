import Config

# `resolve_side/4` reads VEHICLE, prepends the vehicle's compiled ebin
# and returns `{vehicle, composer}`; `nil` without VEHICLE or in `:test`.
case OvcsVehicle.Firmware.resolve_side(
       :vision,
       __DIR__,
       config_env(),
       Application.compile_env(:vision_firmware, :vehicle)
     ) do
  nil ->
    :ok

  {vehicle, vision} ->
    config :vision_core, :vehicle, vision
    config :ovcs_vehicle, :module, vehicle

    # Stable SSH host keys from the vehicle's priv (`./ovcs host-keys`).
    # Without them NervesSSH generates keys under /data on first boot.
    # `:nerves_ssh` is not a host dep.
    if Application.spec(:nerves_ssh, :vsn) do
      if dir = OvcsVehicle.Firmware.ssh_system_dir(vehicle, "vision") do
        config :nerves_ssh, system_dir: String.to_charlist(dir)
      end
    end
end

if System.get_env("PHX_SERVER") do
  config :vision_api, VisionApiWeb.Endpoint, server: true
end
