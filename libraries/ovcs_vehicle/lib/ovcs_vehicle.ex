defmodule OvcsVehicle do
  @moduledoc """
  Top-level contract for an OVCS vehicle package.

  A vehicle package is a single Mix app that bundles both the VMS and
  infotainment sides of a vehicle. The top-level module implements this
  behaviour; it exposes the two side-specific composers so that
  `vms_core` and `infotainment_core` can dispatch through a single
  reference configured as `:vehicle` in their application environment.
  """

  @callback name() :: String.t()
  @callback vms() :: module()
  @callback infotainment() :: module()
  @callback can_config_otp_app() :: atom()
  @callback nerves_target(:vms | :infotainment) :: atom()

  @optional_callbacks [infotainment: 0]
end
