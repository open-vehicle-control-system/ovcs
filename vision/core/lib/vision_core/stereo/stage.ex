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
  names of its options, and implements `options/1` and, for live
  settings, `set_option/3`: the pipeline refuses at start a stage with
  live settings and no `set_option/3`. Live settings change while
  running; build settings (`applies: :build`) are fixed when the stage
  starts, and listed so they can be shown. Keys are unique within a
  stage, and the settings become the unit's vision parameters
  (`VisionCore.Parameters`), addressed by stage
  (`VisionCore.Stereo.Pipeline.set_options/3`). `init/2` builds them
  from its options with `VisionCore.Parameters.Check.init_settings/3`,
  and `set_option/3` checks a change with
  `VisionCore.Parameters.Check.change_setting/4`, so a stage refuses
  what the registry refuses, and an option it does not declare.
  """

  alias VisionCore.Stereo.Pair

  @typedoc "The stage's own state, from `init/2`."
  @type state :: term()

  @typedoc """
  What every stage may use, fixed until the calibration is reloaded:
  the `:width` and `:height` the stages work at, the `:frame_width` and
  `:frame_height` of the submitted frames, each side's
  `CameraCalibration` scaled to the working size (`:left_calibration`,
  `:right_calibration`), and the stereo geometry derived from them
  (`:focal_length_px`, `:baseline_m`, `:principal_point`).
  """
  @type context :: %{
          width: pos_integer(),
          height: pos_integer(),
          frame_width: pos_integer(),
          frame_height: pos_integer(),
          left_calibration: VisionCore.Ros2.CameraCalibration.t(),
          right_calibration: VisionCore.Ros2.CameraCalibration.t(),
          focal_length_px: float(),
          baseline_m: float(),
          principal_point: {float(), float()}
        }

  @typedoc """
  A setting: its `:type` (`:integer`, `:double`, `:bool` or `:string`),
  its `:range` `{min, max}` with an optional `:step`, or its `:values`,
  the setting of the same stage it must exceed (`:greater_than`), whether
  it changes while running (`applies: :live`, the default) or is fixed at
  start (`:build`), the values of other build settings it only takes
  effect with (`:when`), and a `:description`.
  """
  @type option_spec :: %{
          required(:type) => VisionCore.Parameters.type(),
          optional(:range) => {number(), number()},
          optional(:step) => number(),
          optional(:values) => [term()],
          optional(:greater_than) => atom(),
          optional(:applies) => :live | :build,
          optional(:when) => keyword(),
          optional(:description) => String.t()
        }

  @doc """
  Builds the stage's state from its options and the pipeline's context,
  or says why it cannot: an option it does not declare, or a value its
  spec refuses.
  """
  @callback init(opts :: keyword(), context()) :: {:ok, state()} | {:error, String.t()}

  @doc "Runs the stage on one pair."
  @callback run(Pair.t(), state()) :: {:ok, Pair.t(), state()} | {:error, term(), state()}

  @doc "The `Pair` fields the stage reads."
  @callback requires() :: [atom()]

  @doc "The `Pair` fields the stage fills."
  @callback provides() :: [atom()]

  @doc "One line on what the stage does."
  @callback summary() :: String.t()

  @doc """
  A paragraph for someone tuning the stage: what it does, why it matters,
  what its settings change and what to watch on the dashboard.
  """
  @callback explanation() :: String.t()

  @doc "The stage's settings: the live ones `set_option/3` accepts, and its build settings."
  @callback option_specs() :: [{atom(), option_spec()}]

  @doc "The value of every setting in `option_specs/0`."
  @callback options(state()) :: %{atom() => term()}

  @doc """
  Changes one live setting from the next pair on, or says why it cannot:
  a key that is not a live setting, or a value its spec refuses.
  """
  @callback set_option(state(), atom(), term()) :: {:ok, state()} | {:error, String.t()}

  @optional_callbacks summary: 0, explanation: 0, option_specs: 0, options: 1, set_option: 3

  @doc "Whether `module` declares `behaviour` with `@behaviour`, as a stage or a segment does."
  @spec implements?(module(), module()) :: boolean()
  def implements?(module, behaviour) do
    Code.ensure_loaded?(module) and
      behaviour in Enum.concat(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end
end
