defmodule VisionCore.Ros2.Bag.Recording do
  @moduledoc """
  The process that owns a recording's files: a rosbag2 folder, `dir`,
  holding `metadata.yaml` (`VisionCore.Ros2.Bag.Metadata`) and the MCAP
  files `<name>_<n>.mcap`, `n` from 0, as Jazzy's rosbag2 names them;
  Lyrical's writes `<n>_<name>_<local time>.mcap`, and both read the names
  from `metadata.yaml`.

  `write/5` hands it a ROS 2 message, which it writes as rosbag2 stores
  one: CDR with its encapsulation header (`Ros2Zenoh.RmwZenoh.encode_payload/1`),
  on a `cdr` channel per topic, with the `ros2msg` schema of its type
  (`Ros2Zenoh.definition/1`) and the channel metadata rosbag2's MCAP storage
  writes. A file gets a topic's schema and channel before its first message
  on that topic.

  Every `:chunk_interval_ms` the open chunk is closed and the file synced to
  the disk, so a power cut loses at most that much. Past `:max_file_bytes`
  the file is closed and the next message opens the next one.
  `metadata.yaml` is rewritten, through a synced temporary file, at each
  new file and at the stop. The first file holds the attachments and, as a
  Metadata record named `recording`, the metadata, which `metadata.yaml`
  also carries as its custom data along with each topic's drops, as
  `dropped:<topic>`.

  Log times never go back within a recording, as MCAP readers expect: a
  log time earlier than the latest written is raised to it, and the time
  given stays the message's publish time.

  `write/5` drops and counts a message, without sending it, while more than
  `:queue` messages wait for this process. A message that does not encode
  is dropped and counted too.

  A write the disk refuses, from a full disk or one pulled out, ends the
  recording: the files are closed as far as the disk allows, `metadata.yaml`
  written if it can be, and only then the reason kept in `status/1`. The process then
  only counts the messages it is handed as drops until `stop/1` stops it
  normally; a disk that refuses the folder at the start leaves it in that
  state from the start.

  `status/1` reads a table this process keeps, without waiting on it, and
  `write/5`, `status/1` and `stop/1` answer even once it has stopped. A
  supervisor does not restart it: a new recording would replace its files.
  """
  use GenServer, restart: :temporary

  alias Ros2Zenoh.RmwZenoh
  alias VisionCore.Mcap.Writer
  alias VisionCore.Ros2.Bag.Metadata

  require Logger

  @options [
    :dir,
    :name,
    compression: :zstd,
    max_file_bytes: 2_000_000_000,
    queue: 256,
    attachments: [],
    metadata: %{},
    chunk_interval_ms: 1_000
  ]

  @metadata_file "metadata.yaml"
  @ros_distro "lyrical"
  @stop_timeout_ms 30_000

  @type status :: %{
          bytes: non_neg_integer(),
          files: non_neg_integer(),
          messages: %{String.t() => pos_integer()},
          dropped: %{String.t() => pos_integer()},
          error: String.t() | nil
        }

  @doc """
  Starts a recording in `:dir`, created if missing.

  Options:
    * `:dir` - the recording's folder
    * `:name` - its files' names before `_<n>.mcap`
    * `:compression` - `:zstd` or `:none`, its chunks' (`:zstd`)
    * `:max_file_bytes` - the size past which a file is closed (`2_000_000_000`)
    * `:queue` - the messages that may wait for this process (`256`)
    * `:attachments` - `{name, media_type, data}` attached to the first file (`[]`)
    * `:metadata` - string keys and values for the first file and `metadata.yaml` (`%{}`)
    * `:chunk_interval_ms` - the time between two chunk closes (`1_000`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, @options)
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Hands the recording `message`, of `message_module`, on `topic` at
  `log_time_ns`; dropped and counted while more than `:queue` messages wait.
  """
  @spec write(pid(), String.t(), module(), struct(), non_neg_integer()) :: :ok
  def write(server, topic, message_module, message, log_time_ns) do
    topic = Ros2Zenoh.full_name(topic)

    with {table, queue} <- :persistent_term.get({__MODULE__, server}, nil),
         {:message_queue_len, waiting} <- Process.info(server, :message_queue_len) do
      if waiting < queue,
        do: GenServer.cast(server, {:write, topic, message_module, message, log_time_ns}),
        else: count_drop(table, topic)
    end

    :ok
  end

  @doc """
  The bytes written to the files, the files begun, the messages written and
  dropped per topic, and why the recording ended early, if it did; `nil`
  once the process has stopped.
  """
  @spec status(pid()) :: status() | nil
  def status(server) do
    case :persistent_term.get({__MODULE__, server}, nil) do
      nil -> nil
      {table, _queue} -> read_status(table)
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Closes the files, writes `metadata.yaml` and stops the process."
  @spec stop(pid()) :: :ok
  def stop(server) do
    GenServer.call(server, :stop, @stop_timeout_ms)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    :ets.insert(table, [{:bytes, 0}, {:files, 0}, {:error, nil}])
    :persistent_term.put({__MODULE__, self()}, {table, Keyword.fetch!(opts, :queue)})

    state = %{
      dir: Keyword.fetch!(opts, :dir),
      name: Keyword.fetch!(opts, :name),
      compression: Keyword.fetch!(opts, :compression),
      max_file_bytes: Keyword.fetch!(opts, :max_file_bytes),
      chunk_interval_ms: Keyword.fetch!(opts, :chunk_interval_ms),
      attachments: Keyword.fetch!(opts, :attachments),
      metadata: Keyword.fetch!(opts, :metadata),
      table: table,
      writer: nil,
      files: [],
      closed_bytes: 0,
      schemas: %{},
      channels: %{},
      topics: %{},
      last_log_time: 0,
      last_flush_ms: now_ms(),
      unsynced: false,
      ended: false,
      unencodable_topics: MapSet.new()
    }

    state =
      attempt(state, fn state ->
        File.mkdir_p!(state.dir)
        open_file(state)
      end)

    {:ok, schedule_tick(state)}
  end

  @impl GenServer
  def handle_cast({:write, topic, _module, _message, _log_time}, %{ended: true} = state) do
    count_drop(state.table, topic)
    {:noreply, state}
  end

  def handle_cast({:write, topic, module, message, log_time}, state) do
    case encode(message) do
      {:ok, payload} ->
        {:noreply, attempt(state, &write_message(&1, topic, module, payload, log_time))}

      {:error, reason} ->
        count_drop(state.table, topic)
        {:noreply, log_unencodable(state, topic, module, reason)}
    end
  end

  @impl GenServer
  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, finish(state)}

  @impl GenServer
  def handle_info(:tick, %{ended: true} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = if due?(state), do: attempt(state, &flush/1), else: state
    {:noreply, schedule_tick(state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    finish(state)
    :persistent_term.erase({__MODULE__, self()})
  end

  defp write_message(state, topic, module, payload, log_time) do
    state = if due?(state), do: flush(state), else: state
    state = state |> ensure_file() |> ensure_channel(topic, module)
    clamped = max(log_time, state.last_log_time)
    sequence = get_in(state.topics, [topic, :message_count]) || 0

    writer =
      Writer.write_message(
        state.writer,
        state.channels[topic],
        sequence,
        clamped,
        log_time,
        payload
      )

    :ets.update_counter(state.table, {:messages, topic}, 1, {{:messages, topic}, 0})
    [file | files] = state.files

    %{
      state
      | writer: writer,
        files: [count_message(file, clamped) | files],
        topics:
          Map.update(state.topics, topic, %{module: module, message_count: 1}, fn topic ->
            %{topic | message_count: topic.message_count + 1}
          end),
        last_log_time: clamped,
        unsynced: true
    }
  end

  defp count_message(file, log_time) do
    %{
      file
      | starting_time: file.starting_time || log_time,
        end_time: log_time,
        message_count: file.message_count + 1
    }
  end

  defp ensure_file(%{writer: nil} = state), do: open_file(state)
  defp ensure_file(state), do: state

  defp ensure_channel(state, topic, module) do
    if Map.has_key?(state.channels, topic) do
      state
    else
      {writer, schema_id} = ensure_schema(state, module)

      {writer, channel_id} =
        Writer.add_channel(writer, schema_id, topic, "cdr", %{
          "offered_qos_profiles" => Metadata.encode_qos_profiles([Metadata.publisher_qos()]),
          "topic_type_hash" => type_hash(module)
        })

      %{
        state
        | writer: writer,
          schemas: Map.put(state.schemas, module, schema_id),
          channels: Map.put(state.channels, topic, channel_id)
      }
    end
  end

  defp ensure_schema(state, module) do
    case state.schemas do
      %{^module => schema_id} ->
        {state.writer, schema_id}

      _schemas ->
        Writer.add_schema(
          state.writer,
          Ros2Zenoh.ros_type(module),
          "ros2msg",
          Ros2Zenoh.definition(module)
        )
    end
  end

  defp open_file(state) do
    index = length(state.files)
    file_name = "#{state.name}_#{index}.mcap"
    path = Path.join(state.dir, file_name)

    writer =
      case Writer.open(path, compression: state.compression) do
        {:ok, writer} -> writer
        {:error, reason} -> raise File.Error, reason: reason, action: "open", path: path
      end

    writer = if index == 0, do: add_attachments_and_metadata(writer, state), else: writer
    :ets.insert(state.table, {:files, index + 1})

    %{
      state
      | writer: writer,
        files: [
          %{path: file_name, starting_time: nil, end_time: nil, message_count: 0} | state.files
        ],
        schemas: %{},
        channels: %{}
    }
    |> put_bytes()
    |> write_metadata_file()
  end

  defp add_attachments_and_metadata(writer, state) do
    now = System.system_time(:nanosecond)

    writer =
      Enum.reduce(state.attachments, writer, fn {name, media_type, contents}, writer ->
        Writer.add_attachment(writer, name, media_type, now, now, contents)
      end)

    if state.metadata == %{},
      do: writer,
      else: Writer.add_metadata(writer, "recording", state.metadata)
  end

  defp due?(state),
    do: state.unsynced and now_ms() - state.last_flush_ms >= state.chunk_interval_ms

  # Closes the open chunk and syncs it, and closes the file once past its size.
  defp flush(state) do
    writer = state.writer |> Writer.close_chunk() |> Writer.sync()
    state = put_bytes(%{state | writer: writer, last_flush_ms: now_ms(), unsynced: false})

    if Writer.bytes_written(writer) >= state.max_file_bytes,
      do: close_file(state),
      else: state
  end

  defp close_file(state) do
    [file | _files] = state.files
    path = Path.join(state.dir, file.path)
    bytes = Writer.bytes_written(state.writer)

    case Writer.close(state.writer) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "close", path: path
    end

    size =
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> size
        {:error, _reason} -> bytes
      end

    put_bytes(%{state | writer: nil, closed_bytes: state.closed_bytes + size, unsynced: false})
  end

  defp put_bytes(state) do
    open_bytes = if state.writer, do: Writer.bytes_written(state.writer), else: 0
    :ets.insert(state.table, {:bytes, state.closed_bytes + open_bytes})
    state
  end

  defp finish(%{ended: true} = state), do: state

  defp finish(state) do
    state =
      attempt(state, fn state ->
        state = if state.writer, do: close_file(state), else: state
        write_metadata_file(state)
      end)

    %{state | ended: true}
  end

  # Runs a step that writes to the disk; a write it refuses ends the recording.
  defp attempt(state, step) do
    step.(state)
  rescue
    error in File.Error -> end_recording(state, Exception.message(error))
  end

  defp end_recording(state, reason) do
    Logger.error("#{inspect(__MODULE__)} #{state.dir}: #{reason}; the recording ends")
    if state.writer, do: Writer.close(state.writer)
    state = %{state | writer: nil, ended: true}

    try do
      write_metadata_file(state)
    rescue
      _error in File.Error -> :ok
    end

    :ets.insert(state.table, {:error, reason})
    state
  end

  defp write_metadata_file(state) do
    path = Path.join(state.dir, @metadata_file)
    temporary = path <> ".tmp"

    with {:ok, file} <- :file.open(temporary, [:raw, :binary, :write]),
         :ok <- write_and_close(file, Metadata.encode(metadata(state))),
         :ok <- :file.rename(temporary, path) do
      state
    else
      {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
    end
  end

  defp write_and_close(file, contents) do
    written = with :ok <- :file.write(file, contents), do: :file.datasync(file)
    closed = :file.close(file)
    if written == :ok, do: closed, else: written
  end

  defp metadata(state) do
    drops =
      for {{:dropped, topic}, count} <- :ets.tab2list(state.table),
          into: %{},
          do: {"dropped:" <> topic, Integer.to_string(count)}

    %{
      files:
        state.files
        |> Enum.reverse()
        |> Enum.map(fn file ->
          %{
            path: file.path,
            starting_time: file.starting_time,
            duration: if(file.starting_time, do: file.end_time - file.starting_time, else: 0),
            message_count: file.message_count
          }
        end),
      topics:
        state.topics
        |> Enum.sort()
        |> Enum.map(fn {name, topic} ->
          %{
            name: name,
            type: Ros2Zenoh.ros_type(topic.module),
            type_description_hash: type_hash(topic.module),
            offered_qos_profiles: [Metadata.publisher_qos()],
            message_count: topic.message_count
          }
        end),
      custom_data: Map.merge(state.metadata, drops),
      ros_distro: @ros_distro
    }
  end

  defp read_status(table) do
    entries = :ets.tab2list(table)

    %{
      bytes: :ets.lookup_element(table, :bytes, 2),
      files: :ets.lookup_element(table, :files, 2),
      messages: for({{:messages, topic}, count} <- entries, into: %{}, do: {topic, count}),
      dropped: for({{:dropped, topic}, count} <- entries, into: %{}, do: {topic, count}),
      error: :ets.lookup_element(table, :error, 2)
    }
  end

  defp count_drop(table, topic) do
    :ets.update_counter(table, {:dropped, topic}, 1, {{:dropped, topic}, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp encode(message) do
    {:ok, RmwZenoh.encode_payload(message)}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp log_unencodable(state, topic, module, reason) do
    if MapSet.member?(state.unencodable_topics, topic) do
      state
    else
      Logger.warning(
        "#{inspect(__MODULE__)} cannot encode #{inspect(module)} for #{topic}: #{reason}; " <>
          "dropping it; further failures are counted, not logged"
      )

      %{state | unencodable_topics: MapSet.put(state.unencodable_topics, topic)}
    end
  end

  defp type_hash(module) do
    Code.ensure_loaded(module)
    if function_exported?(module, :type_hash, 0), do: module.type_hash(), else: ""
  end

  defp schedule_tick(%{ended: true} = state), do: state

  defp schedule_tick(state) do
    elapsed = now_ms() - state.last_flush_ms

    delay =
      if state.unsynced,
        do: max(state.chunk_interval_ms - elapsed, 0),
        else: state.chunk_interval_ms

    Process.send_after(self(), :tick, delay)
    state
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
