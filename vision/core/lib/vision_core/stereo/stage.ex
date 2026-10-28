defmodule VisionCore.Stereo.Stage do
  @moduledoc """
  One step of `VisionCore.Stereo.Pipeline`. A pair of frames goes
  through the stages in order as a `VisionCore.Stereo.Pair`: each stage
  reads the fields it `requires/0` and fills the ones it `provides/0`.
  The pipeline checks at start that every required field is provided
  upstream, so a stage list in the wrong order fails at boot.

  A vehicle swaps, drops or adds stages in its composer; see
  `VisionCore.Stereo.Pipeline.default_stages/1` for the default list.

  A stage whose settings can change while running declares them with
  `option_specs/0` and implements `options/1` and `set_option/3`. Their
  keys are unique across the stages of a pipeline, and become the stereo
  unit's ROS 2 parameters (`VisionCore.Ros2.Stereo.Parameters`).
  """

  alias VisionCore.Stereo.Pair

  @typedoc "The stage's own state, from `init/2`."
  @type state :: term()

  @typedoc """
  What every stage may use, fixed until the calibration is reloaded:
  the capture `:width` and `:height`, each side's `CameraCalibration`
  scaled to that size (`:left_calibration`, `:right_calibration`), and
  the stereo geometry derived from them (`:focal_length_px`,
  `:baseline_m`, `:principal_point`).
  """
  @type context :: %{
          width: pos_integer(),
          height: pos_integer(),
          left_calibration: VisionCore.Ros2.CameraCalibration.t(),
          right_calibration: VisionCore.Ros2.CameraCalibration.t(),
          focal_length_px: float(),
          baseline_m: float(),
          principal_point: {float(), float()}
        }

  @typedoc "A runtime setting: `:type` (`:integer`, `:double` or `:bool`), `:range`, `:description`."
  @type option_spec :: %{required(:type) => atom(), optional(atom()) => term()}

  @doc "Builds the stage's state from its options and the pipeline's context."
  @callback init(opts :: keyword(), context()) :: {:ok, state()} | {:error, String.t()}

  @doc "Runs the stage on one pair."
  @callback run(Pair.t(), state()) :: {:ok, Pair.t(), state()} | {:error, term(), state()}

  @doc "The `Pair` fields the stage reads."
  @callback requires() :: [atom()]

  @doc "The `Pair` fields the stage fills."
  @callback provides() :: [atom()]

  @doc "The settings `set_option/3` accepts."
  @callback option_specs() :: [{atom(), option_spec()}]

  @doc "The settings in force."
  @callback options(state()) :: %{atom() => term()}

  @doc "Changes one setting from the next pair on, or says why it cannot."
  @callback set_option(state(), atom(), term()) :: {:ok, state()} | {:error, String.t()}

  @optional_callbacks option_specs: 0, options: 1, set_option: 3
end
