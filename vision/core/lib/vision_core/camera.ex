defmodule VisionCore.Camera do
  @moduledoc """
  Contract for the camera drivers under `VisionCore.Camera.*`. A driver
  instance represents one image sensor, named by its `:label`: it
  captures and fans frames out to registered listeners, as JPEG or grey
  `VisionCore.Camera.Frame`s. A stereo pair is two instances, `"left"` and
  `"right"`.

  A driver MUST:

    * register each instance under `name_for/1` of its label, which the
      stereo unit, its publishers and its parameters use to reach it;
    * accept `register_listener/2` at any time. Listeners receive
      `{:camera_frame, %VisionCore.Camera.Frame{}}` casts as new frames
      become available.

  Drivers stay in raw-capture vocabulary — libcamera/V4L2 details,
  framing, Port lifecycle. Application-side translation (to
  `sensor_msgs/CompressedImage`, etc.) lives in publishers.
  """

  @doc "The registered name of the instance labelled `label`."
  @callback name_for(label :: String.t()) :: atom()

  @callback register_listener(GenServer.server(), pid()) :: :ok

  @doc """
  Change sensor controls while capturing (exposure, focus, ...).
  Returns the controls now in force, or why the request was refused.
  Optional: a driver without runtime controls does not implement it.
  """
  @callback set_controls(GenServer.server(), keyword()) :: {:ok, map()} | {:error, String.t()}

  @doc "The controls in force, as last set."
  @callback controls(GenServer.server()) :: map()

  @doc "Whether one set of controls drives both cameras of a stereo pair."
  @callback shared_controls?() :: boolean()

  @doc """
  The controls `set_controls/2` accepts: `:key`, `:type`, `:range` or
  `:values`, a `:description` and, where the driver has one, a `:default`.
  """
  @callback control_specs() :: [map()]

  @doc "What the camera applied to a recent frame, as it reports it; `nil` before a report."
  @callback live(GenServer.server()) :: map() | nil

  @optional_callbacks set_controls: 2,
                      controls: 1,
                      shared_controls?: 0,
                      control_specs: 0,
                      live: 1
end
