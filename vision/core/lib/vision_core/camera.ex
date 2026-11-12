defmodule VisionCore.Camera do
  @moduledoc """
  Contract for the camera drivers under `VisionCore.Camera.*`. A driver
  instance represents one image sensor, named by its `:label`: it
  captures and publishes frames, as JPEG, grey or RGB
  `VisionCore.Camera.Frame`s. A stereo pair is two instances, `"left"`
  and `"right"`; a camera of its own (`VisionCore.Camera.Unit`) is one,
  labelled with its name's text.

  A driver MUST:

    * register each instance under `name_for/1` of its label, which the
      stereo unit, its parameters and the exporters use to reach it;
    * publish each new frame through `VisionCore.Outputs` as
      `{:camera_frame, %VisionCore.Camera.Frame{}}`, under
      `{:camera_frame, name}`, `name` being the instance's registered name;
      a driver with named outputs (`c:outputs/1`) publishes each output's
      frames under `{:camera_frame, name, output}` instead, each frame
      carrying its output's name as its `:output`;
    * put its `:label` and `:frame_id` options on each
      `VisionCore.Camera.Frame`: the stereo unit gives each side's
      `:frame_id`, and the exporters stamp the frame's messages, and its
      pair's, with it.

  Drivers stay in raw-capture vocabulary — libcamera/V4L2 details,
  framing, Port lifecycle. Application-side translation (to
  `sensor_msgs/CompressedImage`, etc.) lives in the exporters.
  """

  @doc "The registered name of the instance labelled `label`."
  @callback name_for(label :: String.t()) :: atom()

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

  @doc """
  The named outputs of a camera given `opts`, the options it is started
  with, in their configured order, the first the default
  (`VisionCore.Camera.Output.resolve/3`): `{:error, message}` for
  outputs it cannot make. Optional: a driver without it makes one
  output, unnamed.
  """
  @callback outputs(keyword()) :: {:ok, [VisionCore.Camera.Output.t()]} | {:error, String.t()}

  @optional_callbacks set_controls: 2,
                      controls: 1,
                      shared_controls?: 0,
                      control_specs: 0,
                      live: 1,
                      outputs: 1
end
