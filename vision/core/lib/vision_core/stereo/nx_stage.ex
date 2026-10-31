defmodule VisionCore.Stereo.NxStage do
  @moduledoc """
  A `VisionCore.Stereo.Pipeline` stage written in Nx. Like a
  `VisionCore.Stereo.Stage` it has options, `requires/0` and
  `provides/0`, and swaps in a composer's stage list; instead of running
  on a `VisionCore.Stereo.Pair`, it adds its step to a function over
  named tensors.

  At start the pipeline compiles each run of consecutive Nx stages into
  one function, a `VisionCore.Stereo.NxSegment`: a pair's tensors are
  uploaded once, go through every step of the run on the device, and
  come back once.

  The compiled function keeps every value in `state` as a constant, and
  takes `params/2` as inputs: what may change without compiling again,
  such as calibration values, which a calibration reload replaces. A
  stage's settings (`option_specs/0`, `options/1`, `set_option/3`, as
  for a `VisionCore.Stereo.Stage`) are the unit's vision parameters
  (`VisionCore.Parameters`), keys unique within the stage; its live
  settings must be among its params, since the device cannot compile,
  and its build settings are fixed in the compiled function.

  A stage `VisionCore.Stereo.NativeSegment` implements runs natively
  instead when the pipeline computes with `compute: :native`, or when
  its `compute/1` asks for it: consecutive native stages run as one
  native segment, under the same names and settings.
  """

  alias VisionCore.Stereo.{Pair, Stage}

  @type state :: term()

  @doc "Builds the stage's state from its options and the pipeline's context."
  @callback init(opts :: keyword(), Stage.context()) :: {:ok, state()} | {:error, String.t()}

  @doc "The `Pair` fields the stage reads."
  @callback requires() :: [atom()]

  @doc "The `Pair` fields the stage fills, once `finish/3` has run."
  @callback provides() :: [atom()]

  @doc """
  The compiled function's inputs for this stage: tensors, numbers, or
  maps of tensors such as a camera model.
  """
  @callback params(state(), Stage.context()) ::
              %{atom() => Nx.Tensor.t() | number() | %{atom() => Nx.Tensor.t()}}

  @doc """
  Called while tracing: takes the named tensors so far and returns them
  with this stage's outputs added or replaced.
  """
  @callback step(tensors :: map(), params :: map(), state()) :: map()

  @doc """
  Fills the `Pair` from the segment's outputs, on the CPU, after they
  are downloaded. Without it, each output named like a `Pair` field is
  copied there.
  """
  @callback finish(Pair.t(), outputs :: map(), state()) :: Pair.t()

  @doc "One line on what the stage does."
  @callback summary() :: String.t()

  @doc "The stage's settings: the live ones `set_option/3` accepts, and its build settings."
  @callback option_specs() :: [{atom(), Stage.option_spec()}]

  @doc "The value of every setting in `option_specs/0`."
  @callback options(state()) :: %{atom() => term()}

  @doc "Changes one live setting from the next pair on, or says why it cannot."
  @callback set_option(state(), atom(), term()) :: {:ok, state()} | {:error, String.t()}

  @doc """
  Values the stage carries from one pair to the next, with their values
  before the first pair. `step/3` reads them among its params and puts
  their next values in its tensors as `{:carry, name}`; they stay on the
  device.
  """
  @callback carry(state(), Stage.context()) :: %{atom() => Nx.Tensor.t()}

  @doc """
  Where the stage, in `state`, asks to run: compiled with Nx (`:nx`),
  natively (`:native`), or as the pipeline's `:compute` says (`nil`, the
  default).
  """
  @callback compute(state()) :: :nx | :native | nil

  @optional_callbacks summary: 0,
                      finish: 3,
                      option_specs: 0,
                      options: 1,
                      set_option: 3,
                      carry: 2,
                      compute: 1

  @doc "Whether `module` is an Nx stage."
  @spec nx_stage?(module()) :: boolean()
  def nx_stage?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :step, 3)
  end

  @doc "Where `module`, initialised to `state`, asks to run; see `c:compute/1`."
  @spec compute(module(), term()) :: :nx | :native | nil
  def compute(module, state) do
    if function_exported?(module, :compute, 1), do: module.compute(state)
  end
end
