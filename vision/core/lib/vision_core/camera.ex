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

  @doc """
  The controls of `control_specs/0` the instance registered as `server`
  has, on the sensors it found: a driver whose sensors may lack one of
  them publishes `{:camera_controls_changed, server}` under
  `controls_changed_key/1` when they change. Optional: a driver without
  it has every control of `control_specs/0`.
  """
  @callback control_specs(GenServer.server()) :: [map()]

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

  @doc """
  The settings of a camera given `opts`, the options it is started with,
  that are fixed at start, by name, each an integer, a float, a boolean,
  a string, an atom or a `{width, height}` size: a camera of its own
  lists them among its parameters, read-only
  (`VisionCore.Camera.Parameters`). Optional: a driver without it lists
  none.
  """
  @callback fixed_settings(keyword()) :: keyword()

  @doc """
  For a driver that captures both cameras of a stereo pair together:
  `:pair`, the `:stereo` component's options it takes once for both
  cameras, beside `:width`, `:height` and `:fps`, and `:side`, those each
  side takes beside `:frame_id` and `:calibration_path`. The stereo unit
  refuses any other option under a side, and gives each instance the
  pair's options and both sides' as `:left` and `:right`. Optional: a
  driver without it takes any option under a side, each side's options
  its instance's.
  """
  @callback pair_options() :: %{pair: [atom()], side: [atom()]}

  @optional_callbacks pair_options: 0,
                      control_specs: 1,
                      fixed_settings: 1,
                      set_controls: 2,
                      controls: 1,
                      shared_controls?: 0,
                      control_specs: 0,
                      live: 1,
                      outputs: 1

  @doc """
  The `VisionCore.Outputs` key a change of the controls of the instance
  registered as `name` is published under (`c:control_specs/1`).
  """
  @spec controls_changed_key(atom()) :: {:camera_controls, atom()}
  def controls_changed_key(name), do: {:camera_controls, name}
end
