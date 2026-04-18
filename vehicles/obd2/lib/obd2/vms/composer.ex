defmodule Obd2.Vms.Composer do
  @moduledoc """
    Combine all the modules require to run the OBD2 connector
  """
  @behaviour VmsCore.Vehicle

  alias Obd2.Vms

  @impl VmsCore.Vehicle
  defdelegate dashboard_configuration, to:  Obd2.Vms.Composer.Dashboard

  @impl VmsCore.Vehicle
  def can_config_otp_app, do: :obd2
  @impl VmsCore.Vehicle
  def can_config_path, do: "can/vms.yml"

  @impl VmsCore.Vehicle
  def default_can_mapping(:host), do: "obd2:vcan0,ovcs:vcan1"
  def default_can_mapping(:target), do: "obd2:spi0.0,ovcs:spi0.1"

  @impl VmsCore.Vehicle
  def bus_broker, do: %{port: 1884}

  @impl VmsCore.Vehicle
  def bus_relay do
    %{
      broker: [host: Obd2.broker_host(), port: 1884],
      client_id: "obd2-vms",
      topic_prefix: "ovcs/obd2/bus",
      topics: [:ready_to_drive, :vms_status]
    }
  end

  @impl VmsCore.Vehicle
  def children do
    [
      {Vms, []}
    ]
  end

  @impl VmsCore.Vehicle
  def generic_controllers do
    %{}
  end
end
