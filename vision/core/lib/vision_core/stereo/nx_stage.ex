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

  A stage computes as the pipeline's `:compute` says, unless its options
  in the stage list pin it (`compute: :nx` or `compute: :native`, which
  the pipeline takes out before `init/2`) or its `compute/1` asks for
  one; the pipeline refuses a pin and a `compute/1` that disagree. The
  first of the pipeline's backends (`VisionCore.Stereo.Segment`) that
  takes the stage runs it: a stage that declares a `native_kind/0` runs
  natively under `:native`, in `VisionCore.Stereo.NativeSegment`, and
  consecutive native stages run as one native segment, under the same
  names and settings. One without is compiled under the pipeline's
  `:native`, and refused when it asks for `:native` itself.
  """

  alias VisionCore.Stereo.{Pair, Stage}

  @type state :: term()

  @doc """
  Builds the stage's state from its options and the pipeline's context,
  or says why it cannot: an option it does not declare, or a value its
  spec refuses.
  """
  @callback init(opts :: keyword(), Stage.context()) :: {:ok, state()} | {:error, String.t()}

  @doc "The `Pair` fields the stage reads."
  @callback requires() :: [atom()]

  @doc """
  The `Pair` fields the stage fills, once `finish/3` has run, and the
  tensors it leaves on the device for the stages after it in its segment
  (`c:device_only/0`).
  """
  @callback provides() :: [atom()]

  @doc """
  The compiled function's inputs for this stage: tensors, numbers, or
  maps of tensors such as a camera model. Without it, the stage takes
  none.
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
  are downloaded. Without it, each output named like a field the stage
  `provides/0` is copied there.
  """
  @callback finish(Pair.t(), outputs :: map(), state()) :: Pair.t()

  @doc "One line on what the stage does."
  @callback summary() :: String.t()

  @doc """
  A paragraph for someone tuning the stage: what it does, why it matters,
  what its settings change and what to watch on the dashboard.
  """
  @callback explanation() :: String.t()

  @doc "The stage's settings: the live ones `set_option/3` accepts, and its build settings."
  @callback option_specs() :: [{atom(), Stage.option_spec()}]

  @doc "The value of every setting in `option_specs/0`."
  @callback options(state()) :: %{atom() => term()}

  @doc """
  Changes one live setting from the next pair on, or says why it cannot:
  a key that is not a live setting, or a value its spec refuses.
  """
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
  natively (`:native`), or as its `compute:` pin, else the pipeline's
  `:compute`, says (`nil`, the default).
  """
  @callback compute(state()) :: :nx | :native | nil

  @doc """
  Tensors the stage fills for the stages after it on the device only:
  the segment does not download them.
  """
  @callback device_only() :: [atom()]

  @doc """
  The name of the stage's native implementation in the `stereo_match`
  Port, which `VisionCore.Stereo.NativeSegment` computes it with: a
  stage without one does not compute natively. A vehicle's module that
  wraps a core stage declares that stage's kind, with its
  `native_constants/0`, and no numeric build setting of its own: the
  Port is configured with every numeric build setting and refuses one
  its kind does not take. A refused configuration, or a kind the Port
  has no implementation of, stops the pipeline at its first pair.
  """
  @callback native_kind() :: String.t()

  @doc """
  The constants the stage's step shares with its native implementation,
  by name, which the `stereo_match` Port is configured with beside the
  stage's build settings: each is written once, in the stage.
  """
  @callback native_constants() :: %{atom() => number()}

  @optional_callbacks summary: 0,
                      explanation: 0,
                      params: 2,
                      finish: 3,
                      option_specs: 0,
                      options: 1,
                      set_option: 3,
                      carry: 2,
                      compute: 1,
                      device_only: 0,
                      native_kind: 0,
                      native_constants: 0

  @doc "Whether `module` is an Nx stage: it declares `@behaviour VisionCore.Stereo.NxStage`."
  @spec nx_stage?(module()) :: boolean()
  def nx_stage?(module), do: Stage.implements?(module, __MODULE__)

  @doc """
  The sum of each image in `images`, one `{height, width}` image or a
  stack of them, in two reductions: over axis 1 first, a stack's rows or
  a single image's columns, then over the image's other axis. On the
  C100's GPU, through `nx_iree`, a whole image reduced at once compiles
  to a slow reduction, on one thread.
  """
  @spec image_sums(Nx.Tensor.t()) :: Nx.Tensor.t()
  def image_sums(images) do
    images |> Nx.sum(axes: [1]) |> Nx.sum(axes: [Nx.rank(images) - 2])
  end

  @doc "The inputs `module`, initialised to `state`, takes in `context`; see `c:params/2`."
  @spec params(module(), term(), Stage.context()) :: map()
  def params(module, state, context) do
    if function_exported?(module, :params, 2), do: module.params(state, context), else: %{}
  end

  @doc "Where `module`, initialised to `state`, asks to run; see `c:compute/1`."
  @spec compute(module(), term()) :: :nx | :native | nil
  def compute(module, state) do
    if function_exported?(module, :compute, 1), do: module.compute(state)
  end

  @doc "The tensors `module` keeps on the device; see `c:device_only/0`."
  @spec device_only(module()) :: [atom()]
  def device_only(module) do
    if function_exported?(module, :device_only, 0), do: module.device_only(), else: []
  end

  @doc "The native implementation `module` declares, or `nil`; see `c:native_kind/0`."
  @spec native_kind(module()) :: String.t() | nil
  def native_kind(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :native_kind, 0),
      do: module.native_kind()
  end

  @doc "The constants `module` shares with its native implementation; see `c:native_constants/0`."
  @spec native_constants(module()) :: %{atom() => number()}
  def native_constants(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :native_constants, 0),
      do: module.native_constants(),
      else: %{}
  end
end
