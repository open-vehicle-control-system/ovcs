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
    if config_env() != :test,
      do: raise("vision firmware: set VEHICLE to the vehicle package's top-level module name")

  {vehicle, vision} ->
    config :vision_core, :vehicle, vision
    config :ovcs_vehicle, :module, vehicle

    # Stable SSH host keys from the vehicle's priv (`./ovcs host-keys`).
    # Without them NervesSSH generates keys under /data on first boot.
    # `:nerves_ssh` is not a host dep.
    if Application.spec(:nerves_ssh, :vsn) do
      if system_directory = OvcsVehicle.Firmware.ssh_system_dir(vehicle, "vision") do
        config :nerves_ssh, system_dir: String.to_charlist(system_directory)
      end
    end
end

# The VENTUNO Q has the memory for 512 MiB Vulkan slabs, which keep a stereo
# segment's transient buffers pooled instead of allocated on every pair; IREE
# reads the size when nx_iree creates its devices, after this file runs.
if config_target() == :arduino_ventuno_q,
  do: System.put_env("IREE_HAL_VULKAN_SLAB_SIZE", Integer.to_string(512 * 1024 * 1024))

if System.get_env("PHX_SERVER") do
  config :vision_api, VisionApiWeb.Endpoint, server: true
end
