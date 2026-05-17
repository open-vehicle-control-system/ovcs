defmodule OvcsDrivers.Imu do
  @moduledoc """
  Contract every IMU chip driver in `ovcs_drivers` implements. Lets
  consumers (adapters, control loops, tests) program against a kind
  rather than a specific chip — swapping a `BNO085.I2C` out for a
  hypothetical `Icm20948.I2C` is a one-line change in the
  supervision tree, no consumer code touched.

  A driver implementing this behaviour MUST:

    * Be a named `GenServer` so callers can address it by module.
    * Accept `register_listener/1` calls at any time. Listeners
      receive `{:imu_sample, %OvcsDrivers.Imu.Sample{}}` casts in SI
      units whenever a new sample is available.
    * Accept `enable/0` to start sample production. The driver owns
      any hardware-specific gating (waiting for a reset to settle,
      etc.) so callers can fire and forget.

  Drivers stay in pure hardware vocabulary — Q-point conversions,
  bus protocol, register layouts all live behind this contract.
  Application-side translation (e.g. to ROS / Cantastic types) lives
  in adapters in the consuming application, not here.
  """

  @callback register_listener(pid()) :: :ok
  @callback enable() :: :ok
end
