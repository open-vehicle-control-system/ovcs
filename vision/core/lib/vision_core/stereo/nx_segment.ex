defmodule VisionCore.Stereo.NxSegment do
  @moduledoc """
  A run of consecutive `VisionCore.Stereo.NxStage`s compiled into one
  function when the pipeline starts, and run on each pair as one stage:
  an `NxStereo.NxSegment` on a `Pair`.

  The function takes the `Pair` fields the run needs from earlier stages
  (camera frames as `u8` images) and each stage's `params/2`, and returns
  every tensor but the frames. Outputs come back to the CPU once, and
  each stage's `finish/3` fills the `Pair` from them.

  It is compiled at the pipeline's size with the `:defn_options` of its
  build options (`build/3`), which the pipeline's default backends take
  from its own `:defn_options`. On a device that cannot compile, such as
  the OKdo Nano C100, the module comes from the module cache built on a
  host (`mix vision_core.nx_cache`); since calibration values are
  inputs, a calibration reload needs no new module.

  `send_request/2` takes the pair's inputs and runs the function in a
  `Task`. `collect/4` downloads the outputs in a `Task` of its own, so a
  pair's download overlaps the next pair's device work. What the
  function or the download raises fails that pair only, and the
  pipeline's device timeout bounds both.
  """

  @behaviour VisionCore.Stereo.Segment

  alias VisionCore.Stereo.{NxStage, Pair, Segment, Stage}

  @type t :: NxStereo.NxSegment.t()

  # The Vulkan features Mesa NVK supports on the OKdo Nano C100's GPU.
  @c100_vulkan_features ~w(spirv:v1.3 cap:Shader cap:StorageBuffer8BitAccess cap:Int8
                           ext:SPV_KHR_8bit_storage cap:GroupNonUniform
                           cap:GroupNonUniformArithmetic cap:GroupNonUniformShuffle
                           cap:GroupNonUniformBallot cap:Int64 cap:Int16 cap:Float16
                           cap:StorageBuffer16BitAccess ext:SPV_KHR_16bit_storage)

  @doc """
  The defn options for the OKdo Nano C100's GPU: `nx_iree` compiling for
  Vulkan with the features Mesa NVK supports there, loading modules from
  `module_cache`, a directory or `{app, path}` in that app.
  """
  @spec c100_defn_options(Path.t() | {atom(), Path.t()}) :: keyword()
  def c100_defn_options(module_cache) do
    [
      compiler: NxIREE.Compiler,
      iree_compiler_flags: [
        "--iree-hal-target-backends=vulkan-spirv",
        "--iree-vulkan-target-features=" <> Enum.join(@c100_vulkan_features, ",")
      ],
      iree_module_cache: module_cache
    ]
  end

  @doc """
  Compiles `members`, initialised pipeline stages (`%{module:, name:,
  state:}`), for `context`, with `opts`: `:defn_options` (`[]`, Nx's
  own defaults), how; see `NxStereo.NxSegment`. A missing
  module names the command that builds the module cache.
  """
  @impl VisionCore.Stereo.Segment
  @spec build([map()], Stage.context(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(members, context, opts) do
    case NxStereo.NxSegment.build(members, context, opts) do
      {:error, "no compiled module" <> _rest = message} ->
        {:error, message <> ", with `mix vision_core.nx_cache`"}

      result ->
        result
    end
  end

  @doc "The fields a pair's outputs hold once downloaded, in the order they are packed."
  @spec published(t()) :: [term()]
  defdelegate published(segment), to: NxStereo.NxSegment

  @doc "Every Nx stage, to compile it."
  @impl VisionCore.Stereo.Segment
  @spec accepts?(module(), term(), :nx | :native) :: boolean()
  def accepts?(module, _state, compute), do: compute == :nx and NxStage.nx_stage?(module)

  # Mesa Turnip's features on the VENTUNO Q's Adreno 623, less Int8: without
  # 8-bit storage, IREE emits invalid stores for 8-bit values when it is declared.
  # Its segments pack bytes in 32-bit words.
  @ventuno_q_vulkan_features ~w(spirv:v1.3 cap:Shader cap:Int16 cap:Int64 cap:Float16
                                cap:StorageBuffer16BitAccess ext:SPV_KHR_16bit_storage
                                cap:GroupNonUniform cap:GroupNonUniformVote
                                cap:GroupNonUniformArithmetic cap:GroupNonUniformBallot
                                cap:GroupNonUniformShuffle cap:GroupNonUniformShuffleRelative
                                cap:VariablePointers cap:VariablePointersStorageBuffer)

  @doc """
  The defn options for the Arduino VENTUNO Q's GPU: `nx_iree` compiling
  for Vulkan with the features Mesa Turnip supports on its Adreno 623,
  loading modules from `module_cache`, a directory or `{app, path}` in
  that app. The GPU has no 8-bit storage, so `byte_storage: false` makes
  the segment move its images as packed 32-bit words.
  """
  @spec ventuno_q_defn_options(Path.t() | {atom(), Path.t()}) :: keyword()
  def ventuno_q_defn_options(module_cache) do
    [
      compiler: NxIREE.Compiler,
      iree_compiler_flags: [
        "--iree-hal-target-backends=vulkan-spirv",
        "--iree-vulkan-target-features=" <> Enum.join(@ventuno_q_vulkan_features, ",")
      ],
      iree_module_cache: module_cache,
      byte_storage: false
    ]
  end

  @doc """
  The defn options for the Raspberry Pi 5's CPU: `nx_iree` compiling for
  its Cortex-A76 cores and run on all four, loading modules from
  `module_cache`, a directory or `{app, path}` in that app.
  """
  @spec rpi5_defn_options(Path.t() | {atom(), Path.t()}) :: keyword()
  def rpi5_defn_options(module_cache) do
    [
      compiler: NxIREE.Compiler,
      iree_compiler_flags: [
        "--iree-hal-target-backends=llvm-cpu",
        "--iree-llvmcpu-target-triple=aarch64-unknown-linux-gnu",
        "--iree-llvmcpu-target-cpu=cortex-a76"
      ],
      # Multithreaded, rather than the first GPU or the single-threaded driver.
      iree_runtime_options: [device: "local-task://"],
      iree_module_cache: module_cache
    ]
  end

  @doc """
  The segment with `members` re-initialised for a new `context` of the
  same size: the same function, with new inputs, and what the stages
  carry started over.
  """
  @impl VisionCore.Stereo.Segment
  @spec reload(t(), [map()], Stage.context()) :: t()
  defdelegate reload(segment, members, context), to: NxStereo.NxSegment

  @doc """
  The segment with the member at `index` in a new `state`: its new
  inputs, the same function, and what every stage carries kept.
  """
  @impl VisionCore.Stereo.Segment
  @spec put_member_state(t(), non_neg_integer(), term()) :: t()
  defdelegate put_member_state(segment, index, state), to: NxStereo.NxSegment

  @doc """
  `current` with the values `replied` carries, unless `current` was
  reloaded since `replied`'s pair was sent: the reload started them over.
  """
  @impl VisionCore.Stereo.Segment
  @spec merge_carry(t(), t()) :: t()
  defdelegate merge_carry(current, replied), to: NxStereo.NxSegment

  @doc """
  Takes `pair`'s inputs and runs the compiled function on them in a
  `Task`, without waiting: returns the request, which `response/3` and
  `await/3` recognise its outputs by; or why the inputs do not fit. A
  pair sent before the previous one's response would start from the
  values carried before that pair.
  """
  @impl VisionCore.Stereo.Segment
  @spec send_request(Pair.t(), t()) :: {:ok, Task.t()} | {:error, term()}
  def send_request(%Pair{} = pair, %NxStereo.NxSegment{} = segment) do
    with {:ok, entries} <- Segment.entries(pair, segment.specs),
         do: NxStereo.NxSegment.send_request(entries, segment)
  end

  @doc """
  The outputs of the pair sent as `task`, left on the device, the
  segment carrying its stages' values to the next pair and the
  monotonic time the device was done, or what the compiled function
  raised, when `message` is its reply; `:no_reply` when it is another
  message.
  """
  @impl VisionCore.Stereo.Segment
  @spec response(term(), Task.t(), t()) ::
          {:ok, map(), t(), integer()} | {:error, term()} | :no_reply
  defdelegate response(message, task, segment), to: NxStereo.NxSegment

  @doc "What `response/3` returns for the pair sent as `task`, within `timeout` ms, or `:timeout`."
  @impl VisionCore.Stereo.Segment
  @spec await(Task.t(), t(), timeout()) ::
          {:ok, map(), t(), integer()} | {:error, term()} | :timeout
  defdelegate await(task, segment, timeout), to: NxStereo.NxSegment

  @doc """
  One pair: a pair's device work starts from the values the previous
  one carries.
  """
  @impl VisionCore.Stereo.Segment
  @spec depth() :: pos_integer()
  defdelegate depth, to: NxStereo.NxSegment

  @doc "Each member's time on its own: none, since the members run as one function."
  @impl VisionCore.Stereo.Segment
  @spec member_times(t()) :: [{atom(), non_neg_integer()}]
  defdelegate member_times(segment), to: NxStereo.NxSegment

  @doc """
  Downloads `outputs` from the device, freeing them there, in a `Task`
  that has `timeout` ms, and fills `pair` from them; or what the
  download raised, or `:timeout`.
  """
  @impl VisionCore.Stereo.Segment
  @spec collect(Pair.t(), map(), t(), timeout()) :: {:ok, Pair.t()} | {:error, term()} | :timeout
  def collect(%Pair{} = pair, outputs, %NxStereo.NxSegment{} = segment, timeout) do
    with {:ok, outputs} <- NxStereo.NxSegment.collect(outputs, segment, timeout),
         do:
           {:ok,
            Segment.finish_members(
              segment.members,
              pair,
              Segment.with_entries(pair, segment.specs, outputs)
            )}
  end

  @doc """
  Where the segment, or `defn_options`, run a segment, and with what;
  see `NxStereo.NxSegment.compute/1`.
  """
  @impl VisionCore.Stereo.Segment
  @spec compute(t() | keyword()) :: VisionCore.Parameters.Group.compute()
  defdelegate compute(segment_or_defn_options), to: NxStereo.NxSegment
end
