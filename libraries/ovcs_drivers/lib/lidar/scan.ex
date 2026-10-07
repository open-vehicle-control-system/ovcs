defmodule OvcsDrivers.Lidar.Scan do
  @moduledoc """
  One revolution from a module implementing `OvcsDrivers.Lidar`.

    * `:points` — `{angle, distance, quality}` in measurement order:
      the angle in radians **anticlockwise** from the sensor's forward
      axis seen from above (the ROS convention), in `[0, 2π)`; the
      distance in metres, `0.0` when the sensor got no return; the
      quality in the sensor's own units (0 when no return).
    * `:started_at` — system time in nanoseconds of the first point.
    * `:duration_ns` — time the revolution took.
    * `:range` — `{min, max}` the sensor measures, in metres.
  """
  @enforce_keys [:points, :started_at, :duration_ns, :range]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          points: [{float(), float(), non_neg_integer()}],
          started_at: integer(),
          duration_ns: non_neg_integer(),
          range: {float(), float()}
        }
end
