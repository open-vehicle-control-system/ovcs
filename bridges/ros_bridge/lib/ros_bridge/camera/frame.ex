defmodule RosBridge.Camera.Frame do
  @moduledoc """
  One JPEG frame produced by any module implementing
  `RosBridge.Camera`. All fields are populated.

    * `:label` — driver-assigned identity (e.g. `"left"`, `"right"`).
      Lets a single consumer process multiplex frames from several
      cameras over its mailbox.
    * `:width`, `:height` — pixel dimensions.
    * `:capture_ns` — monotonic capture timestamp in nanoseconds.
      Drivers backed by hardware (libcamera) use the sensor's
      `SensorTimestamp`; the V4L2 / Dummy drivers use
      `System.monotonic_time(:nanosecond)`.
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
