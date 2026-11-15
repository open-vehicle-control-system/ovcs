defmodule VisionCore.Recordings do
  @moduledoc """
  The recordings of the bag exporter (`VisionCore.Ros2.BagExporter`) on
  the disks it records on (`VisionCore.Disks`): listed, started,
  stopped, deleted and archived. The vision API serves them.

  A recording is found by its name among the folders of the mounted
  disks' recordings folders, its parts joined by name
  (`VisionCore.Recording.part_of/1`); a name is never made into a path,
  so no request reaches a folder that is not a recording's. A part on a
  disk that is not mounted is not listed, nor deleted. Only real folders
  count, the recordings folder and each part's, and only a part's
  regular files are archived: a disk's links, which could lead out of
  its recordings, are left out of listings, archives and deletes.

  The recording in progress, if any, is the one the bag exporter
  answers (`VisionCore.Ros2.BagExporter.recording/1`), with the facts
  it counts. The bag exporter is the first the unit runs
  (`VisionCore.Exporters`).

  ## Options

    * `:disks` (`VisionCore.Disks`) — the `VisionCore.Disks` the
      recordings are on.
    * `:exporter` — the runner of the bag exporter, found among the
      unit's exporters without it.
  """

  alias VisionCore.{Disks, Exporters, Recording, Tar}
  alias VisionCore.Ros2.BagExporter

  @typedoc "Why the bag exporter did not answer; see `VisionCore.Ros2.BagExporter`."
  @type unanswered :: :no_bag_exporter | BagExporter.unanswered()

  @typedoc "A recording as one tar archive: its file name, its bytes and its blocks."
  @type archive :: %{filename: String.t(), size: non_neg_integer(), stream: Enumerable.t()}

  @doc """
  The recordings, the newest first; see the module doc for `opts`. The
  bag exporter's error when it does not answer which recording is in
  progress, none on a unit without one or while it does not run.
  """
  @spec list(keyword()) :: {:ok, [Recording.t()]} | {:error, unanswered()}
  def list(opts \\ []) do
    opts = validate!(opts)

    with {:ok, live} <- live_recording(opts) do
      parts = parts_by_name(opts)

      {:ok,
       parts
       |> Map.keys()
       |> Enum.concat(if live, do: [live.name], else: [])
       |> Enum.uniq()
       |> Enum.sort(:desc)
       |> Enum.map(&recording(&1, Map.get(parts, &1, []), live))}
    end
  end

  @doc """
  The recording named `name`, `{:error, :not_found}` for a name no
  recording has, and the bag exporter's error as `list/1` answers it;
  see the module doc for `opts`.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, Recording.t()} | {:error, :not_found | unanswered()}
  def fetch(name, opts \\ []) do
    opts = validate!(opts)
    with {:ok, live} <- live_recording(opts), do: fetch_with(name, live, opts)
  end

  defp fetch_with(name, live, opts) do
    case {Map.fetch(parts_by_name(opts), name), live} do
      {{:ok, parts}, live} -> {:ok, recording(name, parts, live)}
      {:error, %{name: ^name}} -> {:ok, recording(name, [], live)}
      {:error, _live} -> {:error, :not_found}
    end
  end

  @doc """
  Starts a recording of `:preset` (`:review`) with `:clock`
  (`:automatic`), among `VisionCore.Ros2.BagExporter.presets/0` and
  `clocks/0`, and answers it; the bag exporter's refusals, such as
  `{:error, :busy}` while one records and `{:error, {:no_disk, reason}}`,
  and `{:error, :no_bag_exporter}` on a unit without one.
  """
  @spec start(keyword()) ::
          {:ok, Recording.t()}
          | {:error, :busy | {:no_disk, String.t()} | {:failed, String.t()} | unanswered()}
  def start(opts) do
    {preset, opts} = Keyword.pop(opts, :preset, :review)
    {clock, opts} = Keyword.pop(opts, :clock, :automatic)
    opts = validate!(opts)

    with {:ok, runner} <- runner(opts),
         {:ok, started} <- BagExporter.start_recording(runner, preset, clock) do
      {:ok, Recording.put_recording(read_live(started, opts), started)}
    end
  end

  @doc """
  Stops the recording `name` and answers it, stopped;
  `{:error, :stopped}` for a recording that is not in progress,
  `{:error, :not_found}` for a name no recording has, and the bag
  exporter's `{:error, :not_recording}` or `{:error, :other_recording}`
  when the recording ended, or another started, before the stop reached
  it.
  """
  @spec stop(String.t(), keyword()) ::
          {:ok, Recording.t()}
          | {:error, :not_found | :stopped | :not_recording | :other_recording | unanswered()}
  def stop(name, opts) do
    opts = validate!(opts)

    with {:ok, runner} <- runner(opts),
         {:ok, live} <- BagExporter.recording(runner),
         :ok <- check_recording(name, live, opts),
         {:ok, _summary} <- BagExporter.stop_recording(runner, name) do
      fetch_with(name, nil, opts)
    end
  end

  @doc """
  Deletes every part of the recording `name` found on the mounted
  disks; `{:error, :recording}` while it records, `{:error, :not_found}`
  for a name no recording has, and the bag exporter's error when it does
  not answer whether it records.
  """
  @spec delete(String.t(), keyword()) ::
          :ok | {:error, :not_found | :recording | {:failed, String.t()} | unanswered()}
  def delete(name, opts \\ []) do
    case fetch(name, opts) do
      {:ok, %Recording{state: :stopped} = recording} -> delete_parts(recording)
      {:ok, %Recording{state: :recording}} -> {:error, :recording}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_parts(recording) do
    Enum.reduce_while(recording.parts, :ok, fn part, :ok ->
      case File.rm_rf(part.folder) do
        {:ok, _removed} ->
          {:cont, :ok}

        {:error, reason, path} ->
          {:halt, {:error, {:failed, "cannot delete #{path}: #{:file.format_error(reason)}"}}}
      end
    end)
  end

  @doc """
  The recording `name` as one uncompressed tar archive (`VisionCore.Tar`),
  `<name>.tar`, each part a folder of its files, read from the disks as
  the stream is consumed; `{:error, :recording}` while it records, its
  files still growing, `{:error, {:failed, reason}}` for a file it
  cannot read or a name a tar cannot hold, found before any byte is
  sent, and the bag exporter's error when it does not answer whether it
  records.
  """
  @spec archive(String.t(), keyword()) ::
          {:ok, archive()}
          | {:error, :not_found | :recording | {:failed, String.t()} | unanswered()}
  def archive(name, opts \\ []) do
    with {:ok, %Recording{state: :stopped} = recording} <- fetch(name, opts),
         {:ok, entries} <- archive_entries(recording) do
      {:ok, %{filename: name <> ".tar", size: Tar.size(entries), stream: Tar.stream(entries)}}
    else
      {:ok, %Recording{state: :recording}} -> {:error, :recording}
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_entries(recording) do
    recording.parts
    |> Enum.flat_map(&archived_paths/1)
    |> Enum.reduce_while({:ok, []}, fn {name, path}, {:ok, entries} ->
      case Tar.read_entry(name, path) do
        {:ok, entry} ->
          {:cont, {:ok, entries ++ [entry]}}

        {:error, :enametoolong} ->
          {:halt, {:error, {:failed, "#{name} is too long a name for a tar archive"}}}

        {:error, reason} ->
          {:halt, {:error, {:failed, "cannot read #{path}: #{:file.format_error(reason)}"}}}
      end
    end)
  end

  # A part's folder, then its regular files, each with its name in the archive.
  defp archived_paths(part) do
    [
      {part.name <> "/", part.folder}
      | for(
          {file, _bytes} <- Recording.files(part.folder),
          do: {"#{part.name}/#{file}", Path.join(part.folder, file)}
        )
    ]
  end

  defp validate!(opts), do: Keyword.validate!(opts, disks: Disks, exporter: nil)

  defp check_recording(name, %{name: name}, _opts), do: :ok

  defp check_recording(name, _live, opts) do
    case fetch_with(name, nil, opts) do
      {:ok, _stopped} -> {:error, :stopped}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp recording(name, parts, %{name: name} = live),
    do: name |> Recording.read(parts) |> Recording.put_recording(live)

  defp recording(name, parts, _live), do: Recording.read(name, parts)

  # The recording just started, read from its folder.
  defp read_live(started, opts) do
    parts = Map.get(parts_by_name(opts), started.name, [])
    Recording.read(started.name, parts)
  end

  # The folders of every mounted disk's recordings folder, by recording name; a link is no folder.
  defp parts_by_name(opts) do
    for %{recordings_path: recordings, uuid: disk} <- Disks.list(opts[:disks]),
        is_binary(recordings),
        directory?(recordings),
        {:ok, folders} <- [File.ls(recordings)],
        folder <- folders,
        directory?(Path.join(recordings, folder)),
        reduce: %{} do
      parts ->
        {name, number} = Recording.part_of(folder)
        part = %{number: number, folder: Path.join(recordings, folder), disk: disk}
        Map.update(parts, name, [part], &[part | &1])
    end
  end

  defp directory?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  # The recording in progress, `nil` on a unit without a bag exporter or while it does not run.
  defp live_recording(opts) do
    case with({:ok, runner} <- runner(opts), do: BagExporter.recording(runner)) do
      {:ok, live} -> {:ok, live}
      {:error, reason} when reason in [:no_bag_exporter, :not_running] -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runner(opts) do
    case opts[:exporter] do
      nil -> find_runner()
      runner -> {:ok, runner}
    end
  end

  defp find_runner do
    case Enum.find(Exporters.describe(), &(&1.module == BagExporter)) do
      nil ->
        {:error, :no_bag_exporter}

      %{id: id} ->
        case Exporters.fetch_runner(id) do
          {:ok, runner} -> {:ok, runner}
          {:error, :not_found} -> {:error, :no_bag_exporter}
          {:error, :not_running} -> {:error, :not_running}
        end
    end
  end
end
