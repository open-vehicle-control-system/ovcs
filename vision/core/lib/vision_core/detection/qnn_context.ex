defmodule VisionCore.Detection.QnnContext do
  @moduledoc """
  The QNN context binary of a DLC, generated on the board: a context
  binary is tied to the chip and the QAIRT version, so none ships with
  the firmware.

  `ensure/2` keeps one binary per DLC and QAIRT in the cache directory,
  named after the first 16 hex characters of a SHA-256 over the DLC's
  bytes, `libQnnHtp.so`'s and the HTP graph options, so a new model, a
  QAIRT update or new options make a new one. It runs QAIRT's
  `qnn-context-binary-generator` when the binary is missing, then removes
  the others.

  The generator prepares the DLC's graphs at the HTP's graph optimisation
  level 3, its highest, through a backend extension config
  (`libQnnHtpNetRunExtensions.so`) that names them: the Port program reads
  their names from the DLC (`<executable> --graph-names <dlc>`). The two
  JSON files are written next to the binary.
  """

  # QAIRT's HTP backend extension options for each graph.
  @htp_graph_options %{"O" => 3}
  @backend_config "backend_config.json"
  @htp_config "htp_backend_extensions.json"

  @type opts :: [
          qairt_dir: Path.t(),
          dsp_library_path: Path.t(),
          cache_dir: Path.t(),
          executable: Path.t(),
          runner: (String.t(), [String.t()], [{String.t(), String.t()}] ->
                     {String.t(), non_neg_integer()})
        ]

  @doc """
  The context binary of `dlc_path`, generated when missing.

  Options: `:qairt_dir`, `:dsp_library_path`, `:cache_dir` and
  `:executable`, the Port program that reads the DLC's graph names
  (required), and `:runner`, which runs a program as `(command, args, env)
  -> {output, status}` (`System.cmd/3` by default).
  """
  @spec ensure(Path.t(), opts()) :: {:ok, Path.t()} | {:error, term()}
  def ensure(dlc_path, opts) do
    qairt_dir = Keyword.fetch!(opts, :qairt_dir)
    cache_dir = Keyword.fetch!(opts, :cache_dir)
    library = Path.join(qairt_dir, "lib/libQnnHtp.so")

    with {:ok, dlc} <- read(dlc_path, :missing_dlc),
         {:ok, backend} <- read(library, :missing_qairt) do
      key =
        :crypto.hash(:sha256, [dlc, backend, Jason.encode!(@htp_graph_options)])
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      binary = Path.join(cache_dir, key <> ".bin")

      if File.exists?(binary),
        do: {:ok, binary},
        else: generate(dlc_path, library, key, binary, opts)
    end
  end

  @doc """
  The environment QNN needs: its libraries, and the HTP's DSP libraries
  with the board's own.
  """
  @spec env(Path.t(), Path.t()) :: [{String.t(), String.t()}]
  def env(qairt_dir, dsp_library_path) do
    [
      {"LD_LIBRARY_PATH", Path.join(qairt_dir, "lib")},
      {"ADSP_LIBRARY_PATH", "#{qairt_dir}/lib/hexagon-v75/unsigned;#{dsp_library_path}"}
    ]
  end

  defp read(path, missing) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, {missing, path}}
    end
  end

  defp generate(dlc_path, library, key, binary, opts) do
    qairt_dir = Keyword.fetch!(opts, :qairt_dir)
    cache_dir = Keyword.fetch!(opts, :cache_dir)
    runner = Keyword.get(opts, :runner, &System.cmd(&1, &2, env: &3, stderr_to_stdout: true))
    env = env(qairt_dir, Keyword.fetch!(opts, :dsp_library_path))

    with {:ok, graph_names} <-
           graph_names(dlc_path, Keyword.fetch!(opts, :executable), runner, env) do
      File.mkdir_p!(cache_dir)
      config = write_config(qairt_dir, cache_dir, graph_names)

      args =
        ["--backend", library, "--dlc_path", dlc_path] ++
          ["--binary_file", key, "--output_dir", cache_dir, "--config_file", config]

      case runner.(Path.join(qairt_dir, "bin/qnn-context-binary-generator"), args, env) do
        {_output, 0} -> keep_only(binary, cache_dir)
        {output, status} -> {:error, {:generator_failed, status, output}}
      end
    end
  end

  defp graph_names(dlc_path, executable, runner, env) do
    case runner.(executable, ["--graph-names", dlc_path], env) do
      {output, 0} ->
        case String.split(output, "\n", trim: true) do
          [] -> {:error, {:no_graph_names, dlc_path}}
          names -> {:ok, names}
        end

      {output, status} ->
        {:error, {:graph_names_failed, status, output}}
    end
  end

  # The generator's config, naming the HTP backend extension config, which names the graphs.
  defp write_config(qairt_dir, cache_dir, graph_names) do
    htp_config = Path.join(cache_dir, @htp_config)
    config = Path.join(cache_dir, @backend_config)

    File.write!(
      htp_config,
      Jason.encode!(%{"graphs" => [Map.put(@htp_graph_options, "graph_names", graph_names)]})
    )

    File.write!(
      config,
      Jason.encode!(%{
        "backend_extensions" => %{
          "shared_library_path" => Path.join(qairt_dir, "lib/libQnnHtpNetRunExtensions.so"),
          "config_file_path" => htp_config
        }
      })
    )

    config
  end

  defp keep_only(binary, cache_dir) do
    if File.exists?(binary) do
      for stale <- Path.wildcard(Path.join(cache_dir, "*.bin")),
          stale != binary,
          do: File.rm(stale)

      {:ok, binary}
    else
      {:error, {:no_context_binary, binary}}
    end
  end
end
