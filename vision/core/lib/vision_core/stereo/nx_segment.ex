defmodule VisionCore.Stereo.NxSegment do
  @moduledoc """
  A run of consecutive `VisionCore.Stereo.NxStage`s compiled into one
  function when the pipeline starts, and run on each pair as one stage.

  The function takes the `Pair` fields the run needs from earlier stages
  (camera frames as `u8` images) and each stage's `params/2`, and returns
  every tensor but the frames. Outputs come back to the CPU once, and
  each stage's `finish/3` fills the `Pair` from them.

  It is compiled at the pipeline's size with the pipeline's
  `:defn_options`. On a device that cannot compile, such as the OKdo
  Nano C100, the module comes from the module cache built on a host
  (`mix vision_core.nx_cache`); since calibration values are inputs, a
  calibration reload needs no new module.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{Pair, Stage}

  @enforce_keys [:members, :entry, :shapes, :function, :params, :context]
  defstruct [:members, :entry, :shapes, :function, :params, :context]

  @type t :: %__MODULE__{}

  @frames [:left_frame, :right_frame]
  @images [:left, :right]
  @maps [:disparity, :depth_m]

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
  state:}`), for `context`.
  """
  @spec build([map()], Stage.context(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(members, context, defn_options) do
    entry = entry_fields(members)
    params = params(members, context)
    entry_templates = Map.new(entry, &{&1, entry_template(&1, context)})
    shapes = Map.new(entry_templates, fn {field, template} -> {field, Nx.shape(template)} end)

    with {:ok, function} <-
           compile(
             &run_steps(members, &1, &2),
             [entry_templates, Nx.to_template(params)],
             defn_options
           ) do
      {:ok,
       %__MODULE__{
         members: members,
         entry: entry,
         shapes: shapes,
         function: function,
         params: params,
         context: context
       }}
    end
  end

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
  Compiles everything the pipeline started with `pipeline_opts` compiles
  (its segments, and any stage compiling its own function) into the
  module cache `dir`, with the compiler and flags of its
  `:defn_options`, without loading them: a host with EXLA builds it for
  any device.
  """
  @spec build_cache(keyword(), Path.t()) :: :ok | {:error, String.t()}
  def build_cache(pipeline_opts, dir) do
    File.mkdir_p!(dir)

    defn_options =
      pipeline_opts
      |> Keyword.get(:defn_options, [])
      |> Keyword.put(:iree_module_cache, dir)
      |> Keyword.put(:cache_only, true)

    opts =
      pipeline_opts
      |> Keyword.put(:defn_options, defn_options)
      |> Keyword.put(:name, :nx_cache_pipeline)

    compile_pipeline(opts)
  end

  # In a task, so the exit of a pipeline that fails to start stays there.
  defp compile_pipeline(opts) do
    Task.async(fn ->
      Process.flag(:trap_exit, true)

      with {:ok, pipeline} <- start_pipeline(opts),
           do: GenServer.stop(pipeline)
    end)
    |> Task.await(:infinity)
  end

  defp start_pipeline(opts) do
    case VisionCore.Stereo.Pipeline.start_link(opts) do
      {:ok, pipeline} ->
        {:ok, pipeline}

      {:error, {%{__exception__: true} = error, _stacktrace}} ->
        {:error, Exception.message(error)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "The segment with `members` re-initialised for a new `context` of the same size."
  @spec reload(t(), [map()], Stage.context()) :: t()
  def reload(%__MODULE__{} = segment, members, context),
    do: %{segment | members: members, params: params(members, context), context: context}

  @doc "The runtime settings of the segment's stages."
  @spec option_specs(t()) :: [{atom(), Stage.option_spec()}]
  def option_specs(%__MODULE__{members: members}), do: Enum.flat_map(members, &member_specs/1)

  @doc "The settings in force."
  @spec options(t()) :: map()
  def options(%__MODULE__{members: members}) do
    members
    |> Enum.filter(&function_exported?(&1.module, :options, 1))
    |> Enum.reduce(%{}, &Map.merge(&2, &1.module.options(&1.state)))
  end

  @doc "Changes one setting of the stage that declares it: new inputs, the same function."
  @spec set_option(t(), atom(), term()) :: {:ok, t()} | {:error, String.t()}
  def set_option(%__MODULE__{members: members} = segment, key, value) do
    index = Enum.find_index(members, &List.keymember?(member_specs(&1), key, 0))
    member = Enum.at(members, index)

    with {:ok, state} <- member.module.set_option(member.state, key, value) do
      {:ok,
       reload(segment, List.replace_at(members, index, %{member | state: state}), segment.context)}
    end
  end

  defp member_specs(member) do
    if function_exported?(member.module, :option_specs, 0),
      do: member.module.option_specs(),
      else: []
  end

  @doc "Runs the segment on `pair`, in the shape of `c:VisionCore.Stereo.Stage.run/2`."
  @spec run(Pair.t(), t()) :: {:ok, Pair.t(), t()} | {:error, term(), t()}
  def run(%Pair{} = pair, %__MODULE__{} = segment) do
    case dispatch(pair, segment) do
      {:ok, outputs, segment} -> {:ok, collect(pair, outputs, segment), segment}
      {:error, reason} -> {:error, reason, segment}
    end
  end

  @doc """
  The first half of `run/2`: the segment's outputs for `pair`, left on
  the device, and the segment carrying its stages' values to the next
  pair (`c:VisionCore.Stereo.NxStage.carry/2`). It changes no process
  state, so it may run in another process while the previous pair is
  collected.
  """
  @spec dispatch(Pair.t(), t()) :: {:ok, map(), t()} | {:error, term()}
  def dispatch(%Pair{} = pair, %__MODULE__{} = segment) do
    with {:ok, entry} <- entry_values(pair, segment) do
      {carried, outputs} =
        segment.function.(entry, segment.params)
        |> Map.split_with(fn {key, _tensor} -> match?({:carry, _index, _name}, key) end)

      params =
        Enum.reduce(carried, segment.params, fn {{:carry, index, name}, tensor}, params ->
          put_in(params, [index, name], tensor)
        end)

      {:ok, outputs, %{segment | params: params}}
    end
  end

  @doc "The second half of `run/2`: downloads `outputs` and fills `pair` from them."
  @spec collect(Pair.t(), map(), t()) :: Pair.t()
  def collect(%Pair{} = pair, outputs, %__MODULE__{} = segment) do
    outputs =
      Map.new(outputs, fn {key, tensor} ->
        {key, Nx.backend_transfer(tensor, Nx.BinaryBackend)}
      end)

    Enum.reduce(segment.members, pair, &finish(&1, &2, outputs))
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
    |> Map.drop(@frames)
  end

  # The fields the run reads that no member before the reader provides.
  defp entry_fields(members) do
    {entry, _provided} =
      Enum.reduce(members, {[], MapSet.new()}, fn member, {entry, provided} ->
        needed =
          Enum.reject(member.module.requires(), &(MapSet.member?(provided, &1) or &1 in entry))

        {entry ++ needed, MapSet.union(provided, MapSet.new(member.module.provides()))}
      end)

    entry
  end

  defp params(members, context) do
    members
    |> Enum.with_index()
    |> Map.new(fn {member, index} ->
      values = Map.merge(member.module.params(member.state, context), carry(member, context))
      {index, Map.new(values, fn {key, value} -> {key, to_input(value)} end)}
    end)
  end

  defp carry(member, context) do
    if function_exported?(member.module, :carry, 2),
      do: member.module.carry(member.state, context),
      else: %{}
  end

  defp to_input(value) when is_number(value), do: Nx.tensor(value, type: :f32)
  defp to_input(value), do: value

  defp entry_template(field, context) when field in @frames,
    do: Nx.template({context.frame_height, context.frame_width}, :u8)

  defp entry_template(field, context) when field in @images,
    do: Nx.template({context.height, context.width}, :u8)

  defp entry_template(field, context) when field in @maps,
    do: Nx.template({context.height, context.width}, :f32)

  defp entry_template(field, _context),
    do: raise(ArgumentError, "an Nx stage cannot read #{inspect(field)} from a CPU stage")

  # Each entry as a tensor of the shape the function was compiled for.
  defp entry_values(pair, segment) do
    Enum.reduce_while(segment.entry, {:ok, %{}}, fn field, {:ok, values} ->
      expected = Map.fetch!(segment.shapes, field)

      case entry_value(pair, field) do
        {:ok, %Nx.Tensor{shape: ^expected} = tensor} ->
          {:cont, {:ok, Map.put(values, field, tensor)}}

        {:ok, tensor} ->
          {:halt, {:error, {:frame_size, field, Nx.shape(tensor), expected}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp entry_value(pair, field) when field in @frames,
    do: Frame.to_tensor(Map.fetch!(pair, field))

  defp entry_value(pair, field) do
    case Map.fetch!(pair, field) do
      %Nx.Tensor{} = tensor -> {:ok, tensor}
      other -> {:error, {:not_a_tensor, field, other}}
    end
  end

  defp finish(member, pair, outputs) do
    if function_exported?(member.module, :finish, 3) do
      member.module.finish(pair, outputs, member.state)
    else
      member.module.provides()
      |> Enum.filter(&Map.has_key?(outputs, &1))
      |> Enum.reduce(pair, &Map.put(&2, &1, Map.fetch!(outputs, &1)))
    end
  end

  @doc """
  The `:defn_options` of a pipeline `context`; for a context without
  them, `config :vision_core, :nx_defn_options`, else EXLA where it is
  loaded (a workstation), else Nx's evaluator.
  """
  @spec defn_options(map()) :: keyword()
  def defn_options(context), do: Map.get_lazy(context, :defn_options, &default_defn_options/0)

  defp default_defn_options do
    cond do
      options = Application.get_env(:vision_core, :nx_defn_options) -> options
      Code.ensure_loaded?(EXLA) -> [compiler: EXLA]
      true -> []
    end
  end

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
