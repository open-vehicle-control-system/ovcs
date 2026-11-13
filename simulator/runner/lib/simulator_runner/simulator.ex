defmodule SimulatorRunner.Simulator do
  @moduledoc """
  Reads a vehicle's simulated hardware, `t:OvcsVehicle.simulator/0`,
  into what Cantastic and `SimulatorCore.Hardware` take. Pure.
  """

  @doc "The vehicle's `simulator/0`. Raises when the vehicle declares none."
  @spec fetch!(module()) :: OvcsVehicle.simulator()
  def fetch!(vehicle) do
    Code.ensure_loaded(vehicle)

    if function_exported?(vehicle, :simulator, 0),
      do: vehicle.simulator(),
      else: raise(ArgumentError, "#{inspect(vehicle)} declares no simulator/0 to run")
  end

  @doc ~S"""
  A host CAN mapping, `"network:interface"` pairs separated by commas,
  as Cantastic's `:can_network_mappings` takes it.
  """
  @spec can_network_mappings(String.t()) :: [{String.t(), String.t()}]
  def can_network_mappings(mapping) do
    for pair <- String.split(mapping, ",", trim: true) do
      case String.split(pair, ":", parts: 2) do
        [network, interface] -> {network, interface}
        _ -> raise ArgumentError, "CAN mapping entry #{inspect(pair)} is not network:interface"
      end
    end
  end

  @doc """
  `SimulatorCore.Hardware`'s options for `simulator`: its components on
  its motion model, with no world, so the motion is the model's own.
  """
  @spec hardware_options(OvcsVehicle.simulator()) :: keyword()
  def hardware_options(simulator),
    do: [vehicle: simulator.vehicle, simulated_components: simulator.simulated_components]
end
