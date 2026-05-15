defmodule Obd2 do
  @moduledoc """
  Top-level entry point for the OBD2 diagnostic vehicle package.
  """
  @behaviour OvcsVehicle

  @impl OvcsVehicle
  def name, do: "OBD2"
  @impl OvcsVehicle
  def vms, do: Obd2.Vms.Composer
  @impl OvcsVehicle
  def infotainment, do: Obd2.Infotainment.Composer
  @impl OvcsVehicle
  def can_config_otp_app, do: :obd2
  @impl OvcsVehicle
  def vms_target, do: :ovcs_base_can_system_rpi4
  @impl OvcsVehicle
  def infotainment_target, do: :ovcs_base_can_system_rpi5
end
