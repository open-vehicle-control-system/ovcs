defmodule VisionCore.Stereo.Stage do
  @moduledoc """
  One step of `VisionCore.Stereo.Pipeline`. A pair of frames goes
  through the stages in order as a `VisionCore.Stereo.Pair`: each stage
  reads the fields it `requires/0` and fills the ones it `provides/0`.
  The pipeline checks at start that every required field is provided
  upstream, so a stage list in the wrong order fails at boot.

  A vehicle swaps, drops or adds stages in its composer; see
  `VisionCore.Stereo.Pipeline.default_stages/1` for the default list.

  A stage with settings declares them with `option_specs/0`, under the
  names of its options, and implements `options/1` and `set_option/3`.
  Live settings change while running; build settings (`applies:
  :build`) are fixed when the stage starts, and listed so they can be
  shown. Keys are unique within a stage, and the settings become the
  unit's vision parameters (`VisionCore.Parameters`), addressed by
  stage (`VisionCore.Stereo.Pipeline.set_options/3`).
  """

  alias VisionCore.Stereo.Pair

  @typedoc "The stage's own state, from `init/2`."
  @type state :: term()

  @typedoc """
  What every stage may use, fixed until the calibration is reloaded:
  the `:width` and `:height` the stages work at, the `:frame_width` and
  `:frame_height` of the submitted frames, the `:defn_options` Nx code
  is compiled with, each side's
  `CameraCalibration` scaled to the working size (`:left_calibration`, `:right_calibration`), and
  the stereo geometry derived from them (`:focal_length_px`,
  `:baseline_m`, `:principal_point`).
  """
  @type context :: %{
          width: pos_integer(),
          height: pos_integer(),
          frame_width: pos_integer(),
          frame_height: pos_integer(),
          defn_options: keyword(),
          left_calibration: VisionCore.Ros2.CameraCalibration.t(),
          right_calibration: VisionCore.Ros2.CameraCalibration.t(),
          focal_length_px: float(),
          baseline_m: float(),
          principal_point: {float(), float()}
        }

  @typedoc """
  A setting: its `:type` (`:integer`, `:double` or `:bool`), its `:range`
  `{min, max}` with an optional `:step`, or its `:values`, the setting of
  the same stage it must exceed (`:greater_than`), whether it changes
  while running (`applies: :live`, the default) or is fixed at start
  (`:build`), and a `:description`.
  """
  @type option_spec :: %{
          required(:type) => :integer | :double | :bool,
          optional(:range) => {number(), number()},
          optional(:step) => number(),
          optional(:values) => [term()],
          optional(:greater_than) => atom(),
          optional(:applies) => :live | :build,
          optional(:description) => String.t()
        }

  @doc "Builds the stage's state from its options and the pipeline's context."
  @callback init(opts :: keyword(), context()) :: {:ok, state()} | {:error, String.t()}

  @doc "Runs the stage on one pair."
  @callback run(Pair.t(), state()) :: {:ok, Pair.t(), state()} | {:error, term(), state()}

  @doc "The `Pair` fields the stage reads."
  @callback requires() :: [atom()]

  @doc "The `Pair` fields the stage fills."
  @callback provides() :: [atom()]

  @doc "One line on what the stage does."
  @callback summary() :: String.t()

  @doc "The stage's settings: the live ones `set_option/3` accepts, and its build settings."
  @callback option_specs() :: [{atom(), option_spec()}]

  @doc "The value of every setting in `option_specs/0`."
  @callback options(state()) :: %{atom() => term()}

  @doc "Changes one live setting from the next pair on, or says why it cannot."
  @callback set_option(state(), atom(), term()) :: {:ok, state()} | {:error, String.t()}

  @optional_callbacks summary: 0, option_specs: 0, options: 1, set_option: 3
end
