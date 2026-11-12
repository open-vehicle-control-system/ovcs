defmodule VisionCore.Detection.QnnPort do
  @moduledoc """
  What `VisionCore.Detection.Backend.Qnn` and
  `VisionCore.Segmentation.Backend.Qnn` share about their Port: the
  context binary it runs (`VisionCore.Detection.QnnContext`), the program
  started with QNN's environment, its performance profile, and the wait
  before it is reopened.
  """

  alias VisionCore.Detection.QnnContext

  # Detects a wedged Port; not a latency budget.
  @default_infer_timeout_ms 2_000
  @default_reopen_delays_ms [1_000, 2_000, 5_000, 10_000, 30_000]
  @performance_profiles [:burst, :sustained_high_performance, :balanced, :power_saver, :none]

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
  packets reporting its exit status, in QNN's environment
  (`VisionCore.Detection.QnnContext.env/2`).
  """
  @spec open(Path.t(), [String.t()], Path.t(), Path.t()) :: {:ok, port()} | {:error, term()}
  def open(executable, args, qairt_dir, dsp_library_path) do
    env =
      for {name, value} <- QnnContext.env(qairt_dir, dsp_library_path),
          do: {String.to_charlist(name), String.to_charlist(value)}

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
  The wait before reopening a Port that failed `failures` times in a row:
  that entry of `reopen_delays_ms`, its last one past its end.
  """
  @spec reopen_delay_ms([non_neg_integer()], non_neg_integer()) :: non_neg_integer()
  def reopen_delay_ms(reopen_delays_ms, failures),
    do: Enum.at(reopen_delays_ms, failures, List.last(reopen_delays_ms))
end
