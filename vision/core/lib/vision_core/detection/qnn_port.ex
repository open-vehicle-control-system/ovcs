defmodule VisionCore.Detection.QnnPort do
  @moduledoc """
  What `VisionCore.Detection.Backend.Qnn` and
  `VisionCore.Segmentation.Backend.Qnn` share about their Port: the
  context binary it runs (`VisionCore.Detection.QnnContext`), the program
  started with QNN's environment, and its performance profile.

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

  @doc """
  The options every QNN backend takes beside its Port's
  (`VisionCore.Inference.PortBackend`): the board's, `:cache_dir`,
  `:executable` and `:performance`.
  """
  @spec options() :: [atom()]
  def options do
    Keyword.keys(@default_runtime) ++ [:cache_dir, :executable, :performance]
  end

  @doc "The board's options among `opts`, each with its default (see the module doc)."
  @spec runtime(keyword()) :: runtime()
  def runtime(opts) do
    for {key, default} <- @default_runtime, do: {key, Keyword.get(opts, key, default)}
  end

  @doc """
  The context binary of a backend's model, generated when missing
  (`VisionCore.Detection.QnnContext.ensure/2`), from its settings: its
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
end
