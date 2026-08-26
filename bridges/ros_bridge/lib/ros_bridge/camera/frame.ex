defmodule RosBridge.Camera.Frame do
  @moduledoc """
  One JPEG frame produced by any module implementing
  `RosBridge.Camera`. All fields are populated.

    * `:label` — driver-assigned identity (e.g. `"left"`, `"right"`).
      Lets a single consumer process multiplex frames from several
      cameras over its mailbox.
    * `:width`, `:height` — pixel dimensions.
    * `:capture_ns` — capture timestamp in nanoseconds, always on the
      Erlang monotonic timescale (`System.monotonic_time/1`). Drivers
      backed by hardware (libcamera) read the sensor's
      `SensorTimestamp`, which is kernel `CLOCK_MONOTONIC`, and so
      must convert with `RosBridge.Timing.from_kernel_monotonic/1`
      before populating this field — the two clocks differ by ~18
      years. See `RosBridge.Timing`.
    * `:jpeg` — the JPEG-compressed image bytes.
  """
  @enforce_keys [:label, :width, :height, :capture_ns, :jpeg]
  defstruct [:label, :width, :height, :capture_ns, :jpeg]

  @type t :: %__MODULE__{
          label: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          capture_ns: integer(),
          jpeg: binary()
        }
end
