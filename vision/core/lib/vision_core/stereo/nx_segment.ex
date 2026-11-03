defmodule VisionCore.Stereo.NxSegment do
  @moduledoc """
  A run of consecutive `VisionCore.Stereo.NxStage`s compiled into one
  function when the pipeline starts, and run on each pair as one stage.

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

  @enforce_keys [:members, :specs, :function, :params, :carried, :context, :defn_options]
  defstruct [
    :members,
    :specs,
    :function,
    :params,
    :carried,
    :context,
    :defn_options,
    version: 0
  ]

  @type t :: %__MODULE__{}

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
  own defaults), how; see `compile/3`.
  """
  @impl VisionCore.Stereo.Segment
  @spec build([map()], Stage.context(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(members, context, opts) do
    case Keyword.validate(opts, defn_options: []) do
      {:ok, opts} -> compile_members(members, context, opts[:defn_options])
      {:error, unknown} -> {:error, "unknown build options #{inspect(unknown)}"}
    end
  end

  defp compile_members(members, context, defn_options) do
    params = params(members, context)

    with {:ok, specs} <- Segment.entry_specs(members, context),
         entry_templates =
           Map.new(specs, fn {field, {shape, type}} -> {field, Nx.template(shape, type)} end),
         {:ok, function} <-
           compile(
             &run_steps(members, &1, &2),
             [entry_templates, Nx.to_template(params)],
             defn_options
           ) do
      {:ok,
       %__MODULE__{
         members: members,
         specs: specs,
         function: function,
         params: params,
         carried: carried(members, context),
         context: context,
         defn_options: defn_options
       }}
    end
  end

  @doc "Every Nx stage, however it asks to compute: the backend for what no other takes."
  @impl VisionCore.Stereo.Segment
  @spec accepts?(module(), term(), :nx | :native) :: boolean()
  def accepts?(module, _state, _compute), do: NxStage.nx_stage?(module)

  @doc """
  Compiles `function` for `templates` with `defn_options`, an
  `:iree_module_cache` of `{app, path}` being a directory in that app.
  A failure says how to build a missing module. With `cache_only: true`
  and `NxIREE.Compiler`, the module is only written to the module cache,
  for a device of another kind than the host: the function returned
  raises.
  """
  @spec compile(function(), [term()], keyword()) :: {:ok, function()} | {:error, String.t()}
  def compile(function, templates, defn_options) do
    {cache_only?, defn_options} = Keyword.pop(defn_options, :cache_only, false)
    defn_options = resolve_module_cache(defn_options)

    if cache_only? do
      {compiler, defn_options} = Keyword.pop(defn_options, :compiler)
      {:ok, _module} = compiler.to_bytecode(function, templates, defn_options)
      {:ok, cache_only_function(length(templates))}
    else
      {:ok, Nx.Defn.compile(function, templates, defn_options)}
    end
  rescue
    error -> {:error, compile_error_message(error)}
  end

  defp cache_only_function(1), do: fn _input -> raise "compiled for the module cache only" end

  defp cache_only_function(2),
    do: fn _input, _params -> raise "compiled for the module cache only" end

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
  def reload(%__MODULE__{} = segment, members, context) do
    %{
      segment
      | members: members,
        params: params(members, context),
        context: context,
        version: segment.version + 1
    }
  end

  @doc """
  The segment with the member at `index` in a new `state`: its new
  inputs, the same function, and what every stage carries kept.
  """
  @impl VisionCore.Stereo.Segment
  @spec put_member_state(t(), non_neg_integer(), term()) :: t()
  def put_member_state(%__MODULE__{members: members} = segment, index, state) do
    members = List.update_at(members, index, &%{&1 | state: state})
    member = Enum.at(members, index)

    inputs =
      member.module
      |> NxStage.params(member.state, segment.context)
      |> Map.new(fn {key, value} -> {key, to_input(value)} end)

    carried = Map.take(segment.params[index], segment.carried[index])

    %{
      segment
      | members: members,
        params: Map.put(segment.params, index, Map.merge(inputs, carried))
    }
  end

  @doc """
  `current` with the values `replied` carries, unless `current` was
  reloaded since `replied`'s pair was sent: the reload started them over.
  """
  @impl VisionCore.Stereo.Segment
  @spec merge_carry(t(), t()) :: t()
  def merge_carry(
        %__MODULE__{version: version} = current,
        %__MODULE__{version: version} = replied
      ) do
    params =
      Map.new(current.params, fn {index, inputs} ->
        carried = Map.take(Map.fetch!(replied.params, index), current.carried[index])
        {index, Map.merge(inputs, carried)}
      end)

    %{current | params: params}
  end

  def merge_carry(%__MODULE__{} = current, %__MODULE__{}), do: current

  @doc """
  Takes `pair`'s inputs and runs the compiled function on them in a
  `Task`, without waiting: returns the request, which `response/3` and
  `await/3` recognise its outputs by; or why the inputs do not fit. A
  pair sent before the previous one's response would start from the
  values carried before that pair.
  """
  @impl VisionCore.Stereo.Segment
  @spec send_request(Pair.t(), t()) :: {:ok, Task.t()} | {:error, term()}
  def send_request(%Pair{} = pair, %__MODULE__{} = segment) do
    with {:ok, entry} <- Segment.entry_tensors(pair, segment.specs),
         do: {:ok, Task.async(fn -> dispatch(Map.new(entry), segment) end)}
  end

  # The outputs stay on the device; the segment carries the stages' values to the next pair.
  defp dispatch(entry, segment) do
    with {:ok, results} <- call(segment, entry) do
      {carry, outputs} =
        results
        |> Map.drop(device_only(segment.members))
        |> Map.split_with(fn {key, _tensor} -> match?({:carry, _index, _name}, key) end)

      params =
        Enum.reduce(carry, segment.params, fn {{:carry, index, name}, tensor}, params ->
          put_in(params, [index, name], tensor)
        end)

      {:ok, outputs, %{segment | params: params}, System.monotonic_time(:nanosecond)}
    end
  end

  defp call(segment, entry) do
    {:ok, segment.function.(entry, segment.params)}
  rescue
    error -> {:error, error}
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
  def response({ref, dispatched}, %Task{ref: ref}, %__MODULE__{}) do
    Process.demonitor(ref, [:flush])
    dispatched
  end

  def response(_message, %Task{}, %__MODULE__{}), do: :no_reply

  @doc "What `response/3` returns for the pair sent as `task`, within `timeout` ms, or `:timeout`."
  @impl VisionCore.Stereo.Segment
  @spec await(Task.t(), t(), timeout()) ::
          {:ok, map(), t(), integer()} | {:error, term()} | :timeout
  def await(%Task{} = task, %__MODULE__{}, timeout) do
    case Task.yield(task, timeout) do
      {:ok, dispatched} -> dispatched
      nil -> :timeout
    end
  end

  @doc """
  One pair: a pair's device work starts from the values the previous
  one carries.
  """
  @impl VisionCore.Stereo.Segment
  @spec depth() :: pos_integer()
  def depth, do: 1

  @doc "Each member's time on its own: none, since the members run as one function."
  @impl VisionCore.Stereo.Segment
  @spec member_times(t()) :: [{atom(), non_neg_integer()}]
  def member_times(%__MODULE__{}), do: []

  @doc """
  Downloads `outputs` from the device, freeing them there, in a `Task`
  that has `timeout` ms, and fills `pair` from them; or what the
  download raised, or `:timeout`.
  """
  @impl VisionCore.Stereo.Segment
  @spec collect(Pair.t(), map(), t(), timeout()) :: {:ok, Pair.t()} | {:error, term()} | :timeout
  def collect(%Pair{} = pair, outputs, %__MODULE__{} = segment, timeout) do
    download = Task.async(fn -> download(outputs) end)

    case Task.yield(download, timeout) do
      {:ok, {:ok, outputs}} -> {:ok, Segment.finish_members(segment.members, pair, outputs)}
      {:ok, {:error, _reason} = error} -> error
      nil -> :timeout
    end
  end

  defp download(outputs) do
    {:ok, Map.new(outputs, fn {key, tensor} -> {key, Nx.backend_transfer(tensor)} end)}
  rescue
    error -> {:error, error}
  end

  defp run_steps(members, tensors, params) do
    members
    |> Enum.with_index()
    |> Enum.reduce(tensors, fn {member, index}, tensors ->
      tensors
      |> member.module.step(Map.fetch!(params, index), member.state)
      |> Map.new(fn
        {{:carry, name}, tensor} -> {{:carry, index, name}, tensor}
        entry -> entry
      end)
    end)
    |> Map.drop(Segment.frame_fields())
  end

  defp params(members, context) do
    members
    |> Enum.with_index()
    |> Map.new(fn {member, index} ->
      values =
        Map.merge(NxStage.params(member.module, member.state, context), carry(member, context))

      {index, Map.new(values, fn {key, value} -> {key, to_input(value)} end)}
    end)
  end

  # The names of the values each member carries, by its index.
  defp carried(members, context) do
    members
    |> Enum.with_index()
    |> Map.new(fn {member, index} -> {index, Map.keys(carry(member, context))} end)
  end

  defp device_only(members) do
    Enum.flat_map(members, fn member ->
      if function_exported?(member.module, :device_only, 0),
        do: member.module.device_only(),
        else: []
    end)
  end

  defp carry(member, context) do
    if function_exported?(member.module, :carry, 2),
      do: member.module.carry(member.state, context),
      else: %{}
  end

  defp to_input(value) when is_number(value), do: Nx.tensor(value, type: :f32)
  defp to_input(value), do: value

  @doc "Where the segment, or `defn_options`, run a segment, and with what."
  @impl VisionCore.Stereo.Segment
  @spec compute(t() | keyword()) :: VisionCore.Parameters.Group.compute()
  def compute(%__MODULE__{defn_options: defn_options}), do: compute(defn_options)

  def compute(defn_options) do
    {runs_on, backend} =
      case Keyword.get(defn_options, :compiler) do
        NxIREE.Compiler -> iree_target(Keyword.get(defn_options, :iree_compiler_flags, []))
        EXLA -> {exla_device(Keyword.get(defn_options, :client, :host)), :exla}
        _evaluator -> {:cpu, :evaluator}
      end

    %{runs_on: runs_on, implementation: :nx, backend: backend}
  end

  defp iree_target(flags) do
    if Enum.any?(flags, &String.contains?(&1, "vulkan")),
      do: {:gpu, :vulkan},
      else: {:cpu, :llvm_cpu}
  end

  defp exla_device(client) when client in [:cuda, :rocm], do: :gpu
  defp exla_device(_client), do: :cpu

  @doc "`defn_options` with an `:iree_module_cache` of `{app, path}` resolved to that app's directory."
  @spec resolve_module_cache(keyword()) :: keyword()
  def resolve_module_cache(defn_options) do
    case Keyword.fetch(defn_options, :iree_module_cache) do
      {:ok, {app, path}} ->
        Keyword.put(defn_options, :iree_module_cache, Application.app_dir(app, path))

      _other ->
        defn_options
    end
  end

  defp compile_error_message(%{__struct__: NxIREE.CompileError} = error),
    do:
      "no compiled module for it: build the module cache on a host with " <>
        "`mix vision_core.nx_cache` (#{Exception.message(error)})"

  defp compile_error_message(error), do: "cannot compile it: " <> Exception.message(error)
end
