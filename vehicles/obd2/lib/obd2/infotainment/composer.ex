defmodule Obd2.Infotainment.Composer do
  @moduledoc """
    Compose the infotainment configuration for a basic OBD2 vehicle
  """
  @behaviour InfotainmentCore.Vehicle

  alias Obd2.Infotainment

  @impl InfotainmentCore.Vehicle
  defdelegate infotainment_configuration, to: Infotainment.Composer.Infotainment

  @impl InfotainmentCore.Vehicle
  def can_config_otp_app, do: :obd2
  @impl InfotainmentCore.Vehicle
  def can_config_path, do: "can/infotainment.yml"

  @impl InfotainmentCore.Vehicle
  def default_can_mapping(:host), do: "ovcs:vcan1"
  def default_can_mapping(:target), do: "ovcs:can0"

  @impl InfotainmentCore.Vehicle
  def bus_relay do
    %{
      broker: [host: Obd2.broker_host(), port: 1884],
      client_id: "obd2-infotainment",
      topic_prefix: "ovcs/obd2/bus",
      topics: [:ready_to_drive, :vms_status]
    }
  end

  @impl InfotainmentCore.Vehicle
  def children do
    [
      {Obd2.Infotainment, []}
    ]
  end
end
