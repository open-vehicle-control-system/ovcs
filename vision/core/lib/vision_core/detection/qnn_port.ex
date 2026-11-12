defmodule VisionCore.Detection.QnnPort do
  @moduledoc """
  What `VisionCore.Detection.Backend.Qnn` and
  `VisionCore.Segmentation.Backend.Qnn` share about their Port: the
  context binary it runs (`VisionCore.Detection.QnnContext`), the program
  started with QNN's environment, its performance profile, and the wait
  before it is reopened.

  ## The board

  Where QNN is on the board, `runtime/1`'s options, by default the
  Arduino VENTUNO Q's:

    * `:qairt_dir` (`"/opt/qairt"`) — QAIRT's runtime, as the firmware's
      overlay installs it.
    * `:dsp_library_path` (`"/usr/share/qcom/qcs8300/Arduino/Monza/dsp/cdsp"`)
      — the board's DSP libraries.
    * `:dsp_architecture` (`"hexagon-v75"`) — the Hexagon architecture
      of the board's NPU, the directory of QAIRT's DSP libraries for it.
  """

  alias VisionCore.Detection.QnnContext

  # Detects a wedged Port; not a latency budget.
  @default_infer_timeout_ms 2_000
  @default_reopen_delays_ms [1_000, 2_000, 5_000, 10_000, 30_000]
  @default_runtime [
    qairt_dir: "/opt/qairt",
    dsp_library_path: "/usr/share/qcom/qcs8300/Arduino/Monza/dsp/cdsp",
    dsp_architecture: "hexagon-v75"
  ]
  @performance_profiles [:burst, :sustained_high_performance, :balanced, :power_saver, :none]

  @typedoc "Where QNN is on the board; see the module doc."
  @type runtime :: [
          qairt_dir: Path.t(),
          dsp_library_path: Path.t(),
          dsp_architecture: String.t()
        ]

  @doc "The board's options among `opts`, each with its default (see the module doc)."
  @spec runtime(keyword()) :: runtime()
  def runtime(opts) do
    for {key, default} <- @default_runtime, do: {key, Keyword.get(opts, key, default)}
  end

  @doc """
  The context binary of `dlc_path` for the program `executable`, generated
  when missing: `{:error, {:missing_binary, executable}}` without the
  program. `context_opts` are `VisionCore.Detection.QnnContext.ensure/2`'s
  but `:executable`, which is `executable`.
  """
  @spec context(Path.t(), Path.t(), QnnContext.opts()) :: {:ok, Path.t()} | {:error, term()}
  def context(dlc_path, executable, context_opts) do
    if File.exists?(executable),
      do: QnnContext.ensure(dlc_path, Keyword.put(context_opts, :executable, executable)),
      else: {:error, {:missing_binary, executable}}
  end

  @doc """
  Runs `context/3` in a task linked to the caller, which gets its result
  as `Task.async/1` delivers it, so the caller keeps answering while the
  context binary is generated.
  """
  @spec start_context(Path.t(), Path.t(), QnnContext.opts()) :: Task.t()
  def start_context(dlc_path, executable, context_opts),
    do: Task.async(fn -> context(dlc_path, executable, context_opts) end)

  @doc """
  Starts `executable` with `args` as a Port of 4-byte framed binary
  packets reporting its exit status, in QNN's environment on the board
  `runtime` (`VisionCore.Detection.QnnContext.env/3`).
  """
  @spec open(Path.t(), [String.t()], runtime()) :: {:ok, port()} | {:error, term()}
  def open(executable, args, runtime) do
    qnn_env =
      QnnContext.env(runtime[:qairt_dir], runtime[:dsp_library_path], runtime[:dsp_architecture])

    env = for {name, value} <- qnn_env, do: {String.to_charlist(name), String.to_charlist(value)}

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:env, env},
        {:args, args}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  @doc """
  `opts`' `:infer_timeout_ms` (`2000`), a positive integer, and
  `:reopen_delays_ms` (`[1000, 2000, 5000, 10000, 30000]`), a non-empty
  list of non-negative integers; raises `ArgumentError` on another value.
  """
  @spec timings!(keyword()) :: {pos_integer(), [non_neg_integer(), ...]}
  def timings!(opts) do
    infer_timeout_ms = Keyword.get(opts, :infer_timeout_ms, @default_infer_timeout_ms)
    reopen_delays_ms = Keyword.get(opts, :reopen_delays_ms, @default_reopen_delays_ms)

    unless is_integer(infer_timeout_ms) and infer_timeout_ms > 0,
      do: refuse!(:infer_timeout_ms, infer_timeout_ms, "a positive integer")

    unless is_list(reopen_delays_ms) and reopen_delays_ms != [] and
             Enum.all?(reopen_delays_ms, &(is_integer(&1) and &1 >= 0)),
           do:
             refuse!(
               :reopen_delays_ms,
               reopen_delays_ms,
               "a non-empty list of non-negative integers"
             )

    {infer_timeout_ms, reopen_delays_ms}
  end

  @doc """
  The Port's arguments for `opts`' `:performance`, the power vote it
  holds on the HTP: none without it, the Port then voting `burst`;
  `--performance` and the profile for one of `:burst`,
  `:sustained_high_performance`, `:balanced`, `:power_saver` and `:none`
  (no vote); raises `ArgumentError` on another value.
  """
  @spec performance_args!(keyword()) :: [String.t()]
  def performance_args!(opts) do
    case Keyword.fetch(opts, :performance) do
      :error ->
        []

      {:ok, profile} when profile in @performance_profiles ->
        ["--performance", Atom.to_string(profile)]

      {:ok, profile} ->
        refuse!(:performance, profile, "one of #{inspect(@performance_profiles)}")
    end
  end

  defp refuse!(key, value, expected),
    do: raise(ArgumentError, "its #{inspect(key)} is #{expected}, got #{inspect(value)}")

  @doc """
  Whether `reason`, why a Port could not be opened, stays until the
  firmware changes: a missing DLC, QAIRT or program. Any other may be
  gone at the next try.
  """
  @spec final?(term()) :: boolean()
  def final?({missing, _path}) when missing in [:missing_dlc, :missing_qairt, :missing_binary],
    do: true

  def final?(_reason), do: false

  @doc """
  The wait before reopening a Port that failed `failures` times in a row:
  that entry of `reopen_delays_ms`, its last one past its end.
  """
  @spec reopen_delay_ms([non_neg_integer()], non_neg_integer()) :: non_neg_integer()
  def reopen_delay_ms(reopen_delays_ms, failures),
    do: Enum.at(reopen_delays_ms, failures, List.last(reopen_delays_ms))
end
