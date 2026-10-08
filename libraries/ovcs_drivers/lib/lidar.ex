defmodule OvcsDrivers.Lidar do
  @moduledoc """
  Contract every scanning lidar driver in `ovcs_drivers` implements,
  so consumers program against the kind of sensor rather than the
  model.

  A driver implementing this behaviour MUST:

    * Be a named `GenServer` so callers can address it by module.
    * Accept `register_listener/1` calls at any time. Listeners
      receive `{:lidar_scan, %OvcsDrivers.Lidar.Scan{}}` casts, one per
      revolution.
    * Accept `enable/0` to start scanning; the driver owns whatever the
      sensor needs before it measures (motor spin-up, health checks).

  Scans stay in the sensor's own frame and units (see
  `OvcsDrivers.Lidar.Scan`); translation to ROS lives in the consuming
  application.
  """

  @callback register_listener(pid()) :: :ok
  @callback enable() :: :ok
end
