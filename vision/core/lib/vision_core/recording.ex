defmodule VisionCore.Recording do
  @moduledoc """
  One recording of `VisionCore.Ros2.BagExporter`, as
  `VisionCore.Recordings` lists it: its `name`, the folder name of its
  first part, and its parts, the rosbag2 folders `<name>` and
  `<name>_part<n>` on the disks, each with its number, its folder, its
  disk and its bytes.

  A stopped recording's facts are read from its parts' `metadata.yaml`
  (`VisionCore.Ros2.Bag.Metadata`): its custom data's `preset`, `clock`,
  `clock_in_use`, `clock_synchronized` and `started_at`, its messages,
  its drops by topic (`dropped:<topic>`), summed over the parts, and its
  duration, from the first message of its parts to the last. A fact no
  part tells, as in a folder a power cut left without `metadata.yaml`,
  is `nil`. Its bytes are those of its parts' files.

  The recording in progress takes its facts from the bag exporter
  (`put_recording/2`): the `disk` it records on, its duration so far and
  the bytes, messages and drops it counted.
  """

  @metadata_file "metadata.yaml"
  @no_start 9_223_372_036_854_775_807
  @nanoseconds_per_ms 1_000_000

  @typedoc "A part: its number, from 1, its folder's name and path, its disk's UUID and bytes."
  @type part :: %{
          name: String.t(),
          number: pos_integer(),
          folder: Path.t(),
          disk: String.t(),
          bytes: non_neg_integer()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          state: :recording | :stopped,
          preset: String.t() | nil,
          clock: String.t() | nil,
          clock_in_use: String.t() | nil,
          clock_synchronized: boolean() | nil,
          started_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          bytes: non_neg_integer(),
          messages: non_neg_integer() | nil,
          dropped: %{String.t() => pos_integer()},
          disk: String.t() | nil,
          parts: [part()]
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :preset,
    :clock,
    :clock_in_use,
    :clock_synchronized,
    :started_at,
    :duration_ms,
    :messages,
    :disk,
    state: :stopped,
    bytes: 0,
    dropped: %{},
    parts: []
  ]

  @doc """
  The recording and part number of a folder named `folder_name`:
  `<name>_part<n>` is part `n` of `<name>`, any other folder part 1 of
  its own.
  """
  @spec part_of(String.t()) :: {String.t(), pos_integer()}
  def part_of(folder_name) do
    case Regex.run(~r/\A(.+)_part([1-9][0-9]*)\z/, folder_name) do
      [_folder, name, number] when number != "1" -> {name, String.to_integer(number)}
      _first -> {folder_name, 1}
    end
  end

  @doc """
  The stopped recording `name` whose parts are `parts`, each a folder
  with its number and disk, read from the folders.
  """
  @spec read(String.t(), [%{number: pos_integer(), folder: Path.t(), disk: String.t()}]) :: t()
  def read(name, parts) do
    parts = parts |> Enum.sort_by(& &1.number) |> Enum.map(&read_part/1)
    metadata = for part <- parts, part.metadata, do: part.metadata
    custom_data = metadata |> Enum.map(& &1.custom_data) |> Enum.reduce(%{}, &Map.merge(&2, &1))

    %__MODULE__{
      name: name,
      preset: custom_data["preset"],
      clock: custom_data["clock"],
      clock_in_use: custom_data["clock_in_use"],
      clock_synchronized: boolean(custom_data["clock_synchronized"]),
      started_at: started_at(custom_data["started_at"]),
      duration_ms: duration_ms(metadata),
      bytes: parts |> Enum.map(& &1.bytes) |> Enum.sum(),
      messages: if(metadata != [], do: metadata |> Enum.map(& &1.messages) |> Enum.sum()),
      dropped: metadata |> Enum.map(&dropped/1) |> Enum.reduce(%{}, &sum_counts/2),
      parts: Enum.map(parts, &Map.delete(&1, :metadata))
    }
  end

  @doc """
  `recording` as the recording in progress, with the facts the bag
  exporter counts (`VisionCore.Ros2.BagExporter.recording/1`).
  """
  @spec put_recording(t(), VisionCore.Ros2.BagExporter.recording()) :: t()
  def put_recording(%__MODULE__{} = recording, live) do
    %{
      recording
      | state: :recording,
        preset: Atom.to_string(live.preset),
        clock: Atom.to_string(live.clock),
        clock_in_use: Atom.to_string(live.clock_in_use),
        clock_synchronized: live.synchronized,
        started_at: live.started_at,
        duration_ms: live.duration_ms,
        bytes: live.bytes,
        messages: live.messages,
        dropped: live.dropped,
        disk: live.disk
    }
  end

  defp read_part(part) do
    name = Path.basename(part.folder)
    files = folder_files(part.folder)

    %{
      name: name,
      number: part.number,
      folder: part.folder,
      disk: part.disk,
      bytes: files |> Enum.map(fn {_file, bytes} -> bytes end) |> Enum.sum(),
      metadata: read_metadata(part.folder)
    }
  end

  defp folder_files(folder) do
    case File.ls(folder) do
      {:ok, names} ->
        for name <- names,
            {:ok, %File.Stat{type: :regular, size: bytes}} <- [File.stat(Path.join(folder, name))],
            do: {name, bytes}

      {:error, _reason} ->
        []
    end
  end

  # The facts of a part's metadata.yaml, `nil` without one that reads.
  defp read_metadata(folder) do
    with {:ok, %{"rosbag2_bagfile_information" => %{} = bag}} <-
           YamlElixir.read_from_file(Path.join(folder, @metadata_file)),
         %{"message_count" => messages, "files" => files} when is_integer(messages) <- bag do
      %{
        messages: messages,
        spans: spans(files),
        custom_data: custom_data(bag["custom_data"])
      }
    else
      _unreadable -> nil
    end
  end

  # Each file's first and last message times, in nanoseconds, for those with messages.
  defp spans(files) when is_list(files) do
    for %{
          "starting_time" => %{"nanoseconds_since_epoch" => start},
          "duration" => %{"nanoseconds" => duration},
          "message_count" => count
        } <- files,
        is_integer(start) and is_integer(duration) and start != @no_start and count > 0,
        do: {start, start + duration}
  end

  defp spans(_files), do: []

  # YAML reads a plain `2` or `true` the writer meant as text.
  defp custom_data(%{} = custom_data) do
    for {key, value} <- custom_data,
        is_binary(value) or is_integer(value) or is_boolean(value),
        into: %{},
        do: {key, to_string(value)}
  end

  defp custom_data(_none), do: %{}

  defp duration_ms([]), do: nil

  defp duration_ms(metadata) do
    case Enum.flat_map(metadata, & &1.spans) do
      [] ->
        0

      spans ->
        {starts, ends} = Enum.unzip(spans)
        div(Enum.max(ends) - Enum.min(starts), @nanoseconds_per_ms)
    end
  end

  defp dropped(metadata) do
    for {"dropped:" <> topic, count} <- metadata.custom_data,
        {count, ""} <- [Integer.parse(count)],
        into: %{},
        do: {topic, count}
  end

  defp sum_counts(counts, sums), do: Map.merge(sums, counts, fn _topic, a, b -> a + b end)

  defp boolean("true"), do: true
  defp boolean("false"), do: false
  defp boolean(_none), do: nil

  defp started_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, started_at, _offset} -> started_at
      {:error, _reason} -> nil
    end
  end

  defp started_at(_none), do: nil
end
