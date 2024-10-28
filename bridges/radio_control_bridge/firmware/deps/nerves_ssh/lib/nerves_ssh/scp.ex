defmodule NervesSSH.SCP do
  @moduledoc false

  require Logger
  # Only needed for Elixir 1.9
  require Bitwise

  @doc """
  Determines whether a command to exec should be handled by scp
  """
  @spec scp_command?(String.t()) :: boolean()
  def scp_command?("scp -" <> _rest), do: true
  def scp_command?(_other), do: false

  @doc """
  Run the SCP command.
  """
  @spec run(String.t()) :: {:ok, []} | {:error, any()}
  def run("scp " <> options) do
    with :ok <- :io.setopts(encoding: :latin1),
         {:ok, parsed} <- parse_scp(options),
         _ <- run_scp(parsed) do
      {:ok, []}
    end
  end

  defp parse_scp(options) do
    {parsed, _args, invalid} =
      OptionParser.parse(OptionParser.split(options),
        aliases: [
          f: :download,
          v: :verbose,
          t: :upload
        ],
        switches: [download: :string, upload: :string, v: :boolean]
      )

    case invalid do
      [] ->
        {:ok, parsed}

      errors ->
        {:error, "Unexpected scp options: #{inspect(errors)}"}
    end
  end

  defp run_scp(list) do
    verbose = list[:verbose]
    if list[:download], do: download(list[:download], verbose)
    if list[:upload], do: upload(list[:upload], verbose)
  end

  defp upload(dest_path, _verbose?) do
    with :ok <- File.touch(dest_path),
         send_response!(:ok),
         file_info = IO.binread(:line) |> IO.iodata_to_binary(),
         {mode, size, source_path} <- parse_file_info(file_info),
         {:ok, combined_path} <- combine_paths(dest_path, source_path),
         send_response!(:ok),
         :ok <- streamfile_upload(combined_path, size),
         :ok <- File.chmod(combined_path, mode),
         send_response!(:ok),
         :ok <- read_response() do
      :ok
    else
      {:error, posix} ->
        send_response!({:error, "Failed to upload file: #{posix}"})
    end
  end

  defp download(source_path, _verbose?) do
    with :ok <- read_response(),
         {:ok, %{size: size, type: :regular, mode: mode}} <- File.stat(source_path),
         :ok <- IO.binwrite(build_file_info({mode, size, source_path})),
         :ok <- read_response(),
         :ok <- streamfile_download(source_path),
         send_response!(:ok),
         :ok <- read_response() do
      :ok
    else
      {:error, posix} ->
        send_response!({:error, "Failed to download file: #{posix}"})
    end
  end

  defp streamfile_download(path, chunk_size \\ 4096) do
    path
    |> filestream!(chunk_size)
    |> Stream.into(IO.binstream(:stdio, chunk_size))
    |> Stream.run()
  end

  defp streamfile_upload(path, file_size, chunk_size \\ 4096)

  defp streamfile_upload(path, file_size, chunk_size) when file_size >= chunk_size do
    num_chunks = round(file_size / chunk_size)
    process_upload_chunks(path, chunk_size, num_chunks)
    complete_stream_upload(path, file_size - chunk_size * num_chunks, chunk_size)
  end

  defp streamfile_upload(path, file_size, chunk_size) when file_size < chunk_size do
    complete_stream_upload(path, file_size, chunk_size)
  end

  defp complete_stream_upload(_, 0, _) do
    :ok
  end

  defp complete_stream_upload(path, bytes_remaining, chunk_size)
       when bytes_remaining < chunk_size do
    process_upload_chunks(path, bytes_remaining, 1)
  end

  defp process_upload_chunks(path, chunk_size, chunks) do
    IO.binstream(:stdio, chunk_size)
    |> Stream.into(filestream!(path, chunk_size))
    |> Stream.take(chunks)
    |> Stream.run()
  end

  defp read_response() do
    case IO.binread(1) do
      [0] ->
        :ok

      [1] ->
        _resp = IO.binread(:line)
        read_response()

      [2] ->
        {:error, IO.binread(:line)}

      other ->
        Logger.error("Unknown data: #{inspect(other)}")
    end
  end

  defp send_response!(:ok), do: :ok = IO.binwrite([0])
  defp send_response!({:error, message}), do: :ok = IO.binwrite([2, message, ?\n])

  defp parse_file_info("C" <> mode_size_path) do
    [mode_string, size_string, path] = String.split(mode_size_path, " ", parts: 3)
    {mode, ""} = Integer.parse(mode_string, 8)
    {size, ""} = Integer.parse(size_string, 10)
    {mode, size, String.trim(path)}
  end

  defp build_file_info({mode, size, path}) do
    [
      "C",
      "0#{Bitwise.band(mode, 0o1777) |> Integer.to_string(8)} ",
      to_string(size),
      " ",
      Path.basename(path),
      "\n"
    ]
  end

  # dest_path can be a folder or a full pathname
  defp combine_paths(dest_path, source_path) do
    if File.dir?(dest_path) do
      dest_filename = Path.basename(source_path)
      {:ok, Path.join(dest_path, dest_filename)}
    else
      {:ok, dest_path}
    end
  end

  if Version.match?(System.version(), ">= 1.16.0") do
    defp filestream!(path, chunk_size), do: File.stream!(path, chunk_size)
  else
    defp filestream!(path, chunk_size), do: File.stream!(path, [], chunk_size)
  end
end
