defmodule SimulatorRunner do
  @moduledoc """
  Runs a vehicle's simulated hardware on its own BEAM, with no ROS, so
  the VMS boots against hardware that already answers, as on the
  vehicle. **Simulation only, host only.**

  `VEHICLE=<Vehicle> mix run --no-halt` in `simulator/runner` reads the
  vehicle's `simulator/0` (`t:OvcsVehicle.simulator/0`), opens its CAN
  topology on its host mapping, and runs its simulated components in
  `SimulatorCore.Hardware` with no world: `SimulatorCore.FlatGround`
  moves the vehicle.

  Whatever starts the VMS after it polls `ready?/0` over Erlang RPC.
  """

  @doc """
  Whether the vehicle's simulated hardware runs: every simulated
  component has started and its frames are emitted.
  """
  @spec ready?() :: boolean()
  def ready? do
    case Process.whereis(SimulatorRunner.Supervisor) do
      nil -> false
      supervisor -> match?(%{specs: count, active: count}, Supervisor.count_children(supervisor))
    end
  end
end
