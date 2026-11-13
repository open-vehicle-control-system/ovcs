defmodule SimulatorRunner do
  @moduledoc """
  Runs a vehicle's simulated hardware on its own BEAM, with no ROS, so
  the VMS boots against hardware that already answers, as on the
  vehicle. **Simulation only, host only.**

  `VEHICLE=<Vehicle> mix run --no-halt` in `simulator/runner` reads the
  vehicle's `simulator/0` (`t:OvcsVehicle.simulator/0`), opens its CAN
  topology on its host mapping, and runs its simulated components in
  `SimulatorCore.Hardware` with no world: the motion is
  `SimulatorCore.Vehicle`'s own.

  Once the simulated components run and their frames are emitted, the
  runner prints exactly this line on standard output, for whatever
  starts the VMS after it to wait on:

      OVCS simulator ready
  """
end
