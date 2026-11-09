defmodule VisionCore.Detection.QnnContext do
  @moduledoc """
  The QNN context binary of a DLC, generated on the board: a context
  binary is tied to the chip and the QAIRT version, so none ships with
  the firmware.

  `ensure/2` keeps one binary per DLC and QAIRT in the cache directory,
  named after the first 16 hex characters of a SHA-256 over the DLC's
  bytes followed by `libQnnHtp.so`'s, so a new model or a QAIRT update
  makes a new one. It runs QAIRT's `qnn-context-binary-generator` when
  the binary is missing, then removes the others.
  """

  @type opts :: [
          qairt_dir: Path.t(),
          dsp_library_path: Path.t(),
          cache_dir: Path.t(),
          runner: (String.t(), [String.t()], [{String.t(), String.t()}] ->
                     {String.t(), non_neg_integer()})
        ]

  @doc """
  The context binary of `dlc_path`, generated when missing.

  Options: `:qairt_dir`, `:dsp_library_path` and `:cache_dir` (required),
  and `:runner`, which runs the generator as `(command, args, env) ->
  {output, status}` (`System.cmd/3` by default).
  """
  @spec ensure(Path.t(), opts()) :: {:ok, Path.t()} | {:error, term()}
  def ensure(dlc_path, opts) do
    qairt_dir = Keyword.fetch!(opts, :qairt_dir)
    cache_dir = Keyword.fetch!(opts, :cache_dir)
    library = Path.join(qairt_dir, "lib/libQnnHtp.so")

    with {:ok, dlc} <- read(dlc_path, :missing_dlc),
         {:ok, backend} <- read(library, :missing_qairt) do
      key =
        :crypto.hash(:sha256, [dlc, backend]) |> Base.encode16(case: :lower) |> binary_part(0, 16)

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
    File.mkdir_p!(cache_dir)

    args =
      ["--backend", library, "--dlc_path", dlc_path] ++
        ["--binary_file", key, "--output_dir", cache_dir]

    env = env(qairt_dir, Keyword.fetch!(opts, :dsp_library_path))

    case runner.(Path.join(qairt_dir, "bin/qnn-context-binary-generator"), args, env) do
      {_output, 0} ->
        if File.exists?(binary) do
          for stale <- Path.wildcard(Path.join(cache_dir, "*.bin")),
              stale != binary,
              do: File.rm(stale)

          {:ok, binary}
        else
          {:error, {:no_context_binary, binary}}
        end

      {output, status} ->
        {:error, {:generator_failed, status, output}}
    end
  end
end
