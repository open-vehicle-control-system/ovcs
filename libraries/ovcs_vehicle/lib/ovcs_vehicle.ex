defmodule OvcsVehicle do
  @moduledoc """
  Top-level contract for an OVCS vehicle package.

  A vehicle package is a single Mix app that bundles the VMS,
  infotainment, and any bridge firmwares for a vehicle. The
  top-level module implements this behaviour; it exposes the
  side-specific composers so `vms_core`, `infotainment_core`, and
  the shared bridge firmware can dispatch through a single reference
  configured as `:vehicle` in their application environment.

  Bridge firmwares are declared via `bridge_firmwares/0`, which
  returns a map keyed by firmware id. Each entry picks a Nerves
  target and a set of bridge modules to bundle together, so one
  vehicle can run multiple bridge firmwares in parallel (e.g. an
  rpi3a image for radio-control and an rpi5 image for ROS + lidar).
  """

  @type bridge_firmware_id :: String.t()

  @type bridge_firmware :: %{
          required(:target) => atom(),
          required(:bridges) => [module()],
          optional(:can_config_path) => String.t(),
          optional(:default_can_mapping) => %{
            host: String.t(),
            target: String.t()
          }
        }

  @callback name() :: String.t()
  @callback vms() :: module()
  @callback infotainment() :: module()
  @callback bridge_firmwares() :: %{bridge_firmware_id() => bridge_firmware()}
  @callback can_config_otp_app() :: atom()
  @callback nerves_target(:vms | :infotainment) :: atom()

  @optional_callbacks [infotainment: 0, bridge_firmwares: 0]
end
