defmodule RosBridge.Camera do
  @moduledoc """
  Contract for one-camera drivers in `ovcs_drivers`. A driver
  represents a single image sensor: it captures, compresses to JPEG,
  and fans frames out to registered listeners. Stereo / multi-camera
  setups wire up several driver instances and tag them via `:label`.

  A driver implementing this behaviour MUST:

    * Be a uniquely-named `GenServer` (vehicles instantiate more
      than one — the supervisor identifies each by a distinct name,
      typically derived from `:label`).
    * Accept `register_listener/2` at any time. Listeners receive
      `{:camera_frame, %RosBridge.Camera.Frame{}}` casts as new
      frames become available.
    * Accept `enable/1` to start capture. The driver owns any
      hardware-specific gating so callers can fire-and-forget.

  Drivers stay in raw-capture vocabulary — libcamera/V4L2 details,
  JPEG framing, port lifecycle. Application-side translation (to
  `sensor_msgs/CompressedImage`, etc.) lives in publishers.
  """

  @callback register_listener(GenServer.server(), pid()) :: :ok
  @callback enable(GenServer.server()) :: :ok
end
