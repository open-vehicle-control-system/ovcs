defmodule Obd2.Vms do
  @moduledoc """
  Mirrors a subset of OBD2 live data onto the OVCS CAN network so the
  infotainment side can render speed and RPM through the existing
  `drivetrain_status` frame.

  Heavy lifting (full live data, DTCs, vehicle info, UDS sessions, bus
  discovery, DID scans) lives in:

    * `Obd2.Vms.Diagnostics` — standard request loops and on-demand
      actions like Mode 04 / Mode 14 clear-DTC and UDS extended session
      control.

    * `Obd2.Vms.Discovery` — passive frame sniffing and active UDS
      Mode 22 DID walks for ECU fingerprinting.

  Both publish their results on the VMS Bus so the dashboard's metrics
  channel picks them up automatically.
  """
  use GenServer
  require Logger
  alias Decimal, as: D
  alias Cantastic.{OBD2, Emitter}

  @zero D.new(0)

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Emitter.configure(:ovcs, "drivetrain_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "speed" => @zero,
        "rotation_per_minute" => @zero
      },
      enable: true
    })
    OBD2.Request.subscribe(self(), :obd2, "live_data_fast")

    {:ok, %{speed: @zero, rotation_per_minute: @zero}}
  end

  @impl true
  def handle_info({:handle_obd2_response, %OBD2.Response{request_name: "live_data_fast", parameters: parameters}}, state) do
    speed = get_parameter(parameters, "speed", state.speed)
    rotation_per_minute = get_parameter(parameters, "rotation_per_minute", state.rotation_per_minute)

    :ok = Emitter.update(:ovcs, "drivetrain_status", fn data ->
      %{data | "speed" => speed, "rotation_per_minute" => rotation_per_minute}
    end)

    {:noreply, %{state | speed: speed, rotation_per_minute: rotation_per_minute}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp get_parameter(parameters, name, fallback) do
    case parameters do
      %{^name => %OBD2.Parameter{value: value}} -> value
      _ -> fallback
    end
  end
end
