defmodule VisionCore.Inference.QnnPort do
  @moduledoc """
  What `VisionCore.Detection.Backend.Qnn` and
  `VisionCore.Segmentation.Backend.Qnn` share about their Port: the
  context binary it runs (`VisionCore.Inference.QnnContext`), the program
  started with QNN's environment, and its power vote.

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

  alias VisionCore.Inference.QnnContext

  @default_runtime [
    qairt_dir: "/opt/qairt",
    dsp_library_path: "/usr/share/qcom/qcs8300/Arduino/Monza/dsp/cdsp",
    dsp_architecture: "hexagon-v75"
  ]
  @performance_profiles [:burst, :sustained_high_performance, :balanced, :power_saver, :none]
  @max_rpc_polling_us 9999

  @typedoc "Where QNN is on the board; see the module doc."
  @type runtime :: [
          qairt_dir: Path.t(),
          dsp_library_path: Path.t(),
          dsp_architecture: String.t()
        ]

  @doc """
  The options every QNN backend takes beside its Port's
  (`VisionCore.Inference.PortBackend`): the board's, `:cache_dir`,
  `:executable`, `:performance` and `:rpc_polling_us`.
  """
  @spec options() :: [atom()]
  def options do
    Keyword.keys(@default_runtime) ++ [:cache_dir, :executable, :performance, :rpc_polling_us]
  end

  @doc "The board's options among `opts`, each with its default (see the module doc)."
  @spec runtime(keyword()) :: runtime()
  def runtime(opts) do
    for {key, default} <- @default_runtime, do: {key, Keyword.get(opts, key, default)}
  end

  @doc """
  The context binary of a backend's model, generated when missing
  (`VisionCore.Inference.QnnContext.ensure/2`), from its settings: its
  `:dlc_path`, its `:executable`, which reads the DLC's graph names, its
  `:cache_dir` and its board, `:runtime`.
  `{:error, {:missing_binary, executable}}` without the program.
  """
  @spec context(%{
          dlc_path: Path.t(),
          executable: Path.t(),
          cache_dir: Path.t(),
          runtime: runtime()
        }) :: {:ok, Path.t()} | {:error, term()}
  def context(%{dlc_path: dlc_path, executable: executable} = settings) do
    context_opts = [cache_dir: settings.cache_dir, executable: executable] ++ settings.runtime

    if File.exists?(executable),
      do: QnnContext.ensure(dlc_path, context_opts),
      else: {:error, {:missing_binary, executable}}
  end

  @doc """
  Starts `executable` with `args` as a Port of 4-byte framed binary
  packets reporting its exit status, in QNN's environment on the board
  `runtime` (`VisionCore.Inference.QnnContext.env/3`).
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
  The Port's arguments for the power vote it holds on the HTP, from
  `opts`:

    * `:performance` — `--performance` and the profile for one of
      `:burst`, `:sustained_high_performance`, `:balanced`,
      `:power_saver` and `:none` (no vote); none without it, the Port
      then voting `burst`.
    * `:rpc_polling_us` — `--rpc-polling-us` and the time, an integer
      from 0 to 9999, the thread waiting on an execution polls for its
      end before it sleeps until the NPU signals it; none without it, the
      Port then voting 0. It is part of the vote, so `performance: :none`
      takes none.

  Raises `ArgumentError` on another value.
  """
  @spec power_args!(keyword()) :: [String.t()]
  def power_args!(opts) do
    performance = Keyword.fetch(opts, :performance)
    rpc_polling_us = Keyword.fetch(opts, :rpc_polling_us)

    if performance == {:ok, :none} and rpc_polling_us != :error,
      do:
        raise(
          ArgumentError,
          "its :rpc_polling_us is part of the power vote, which performance: :none does not make"
        )

    performance_args!(performance) ++ rpc_polling_args!(rpc_polling_us)
  end

  defp performance_args!(:error), do: []

  defp performance_args!({:ok, profile}) when profile in @performance_profiles,
    do: ["--performance", Atom.to_string(profile)]

  defp performance_args!({:ok, profile}),
    do: refuse!(:performance, profile, "one of #{inspect(@performance_profiles)}")

  defp rpc_polling_args!(:error), do: []

  defp rpc_polling_args!({:ok, micros})
       when is_integer(micros) and micros in 0..@max_rpc_polling_us,
       do: ["--rpc-polling-us", Integer.to_string(micros)]

  defp rpc_polling_args!({:ok, micros}),
    do: refuse!(:rpc_polling_us, micros, "an integer from 0 to #{@max_rpc_polling_us}")

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
end
