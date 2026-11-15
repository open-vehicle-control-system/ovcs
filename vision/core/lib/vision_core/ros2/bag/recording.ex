defmodule VisionCore.Ros2.Bag.Recording do
  @moduledoc """
  The process that owns a recording's files: a rosbag2 folder, `dir`,
  holding `metadata.yaml` (`VisionCore.Ros2.Bag.Metadata`) and the MCAP
  files `<name>_<n>.mcap`, `n` from 0, as Jazzy's rosbag2 names them;
  Lyrical's writes `<n>_<name>_<local time>.mcap`, and both read the names
  from `metadata.yaml`.

  `write/5` encodes a ROS 2 message as rosbag2 stores one, CDR with its
  encapsulation header (`Ros2Zenoh.RmwZenoh.encode_payload/1`), in the
  caller, and this process writes it on a `cdr` channel per topic, with
  the `ros2msg` schema of its type (`Ros2Zenoh.definition/1`) and the
  channel metadata rosbag2's MCAP storage writes. A file gets a topic's schema and channel before its first message
  on that topic.

  The open chunk is closed, and the file synced to the disk, once its
  messages' log times span `:chunk_interval_ms`, or that long after it took
  its first message. Messages that waited for this process, as behind a
  slow sync, fill chunks of that span too, so a power cut loses at most
  that much of the messages written. Past `:max_file_bytes`
  the file is closed and the next message opens the next one.
  `metadata.yaml` is rewritten, through a synced temporary file, at each
  new file and at the stop. The first file holds the attachments, at
  `:start_time_ns`, and, as a Metadata record named `recording`, the
  metadata, which `metadata.yaml` also carries as its custom data along
  with each topic's drops, as `dropped:<topic>`.

  Log times never go back within a recording, as MCAP readers expect: a
  log time earlier than the latest written is raised to it, and the time
  given stays the message's publish time.

  `write/5` hands the message to the recording's
  `VisionCore.Ros2.Bag.Buffer`, which holds it until this process has
  written it, so that the callers never wait on the disk. A message past
  `:buffer_bytes` of payloads held is dropped and counted, as is one that
  does not encode. A stop, or the exit of the process that started the
  recording, writes what the buffer holds, for `:drain_ms` at most, the
  rest counted as dropped, then closes the files. The buffer stops with this
  process, and this process with the buffer.

  ## Disks

  With `:disks`, a `VisionCore.Disks`, and `:disk`, the UUID of the disk
  `dir` is on, the recording goes on on the next disk when it leaves
  one: at a write the disk refuses, or at a check, every
  `:chunk_interval_ms`, that finds the disk below `:free_floor_bytes`
  free, ejecting, ejected or pulled out. It closes the part's file, with
  nothing more written to it after a write the disk refused
  (`VisionCore.Mcap.Writer.abandon/1`), writes its `metadata.yaml` if
  the disk allows, then goes on in `<name>_part<n>`, `n` from 2, in the
  recordings folder of the next disk `VisionCore.Disks.next/3` gives,
  never one it left; a disk that holds a folder of that name already is
  left too, the folder untouched. Each
  part is a rosbag2 folder of its own: its files
  `<name>_part<n>_<i>.mcap`, its schemas and channels, the attachments
  and metadata in its first file, and its own drops in `metadata.yaml`.
  A message the disk refused is written again in the next part; those of
  the chunk the disk lost, or whose sync it refused, are not, and leave
  the messages counted in `status/1` and `metadata.yaml`.

  A write the disk refuses with no disk to go on, or without `:disks`,
  ends the recording: the open file is closed with nothing more written
  to it, and reads up to its last whole chunk
  (`VisionCore.Mcap.Writer.abandon/1`), `metadata.yaml` is written if it
  can be, and only then the reason kept in `status/1`. The process then
  only counts the messages it is handed as drops until `stop/1` stops it
  normally; a disk that refuses the folder at the start leaves it in that
  state from the start.

  `status/1` reads a table this process keeps, without waiting on it, and
  `write/5`, `status/1` and `stop/1` answer even once it has stopped. A
  supervisor does not restart it: a new recording would replace its files.
  """
  use GenServer, restart: :temporary

  alias Ros2Zenoh.RmwZenoh
  alias VisionCore.{Disk, Disks}
  alias VisionCore.Mcap.Writer
  alias VisionCore.Ros2.Bag.{Buffer, Metadata}

  require Logger

  @options [
    :dir,
    :name,
    :start_time_ns,
    compression: :zstd,
    max_file_bytes: 2_000_000_000,
    buffer_bytes: 64 * 1_048_576,
    attachments: [],
    metadata: %{},
    chunk_interval_ms: 1_000,
    disks: nil,
    disk: nil,
    free_floor_bytes: 1_000_000_000,
    drain_ms: 20_000
  ]

  @metadata_file "metadata.yaml"
  @ros_distro "lyrical"
  @stop_timeout_ms 30_000

  @type status :: %{
          bytes: non_neg_integer(),
          files: non_neg_integer(),
          messages: %{String.t() => pos_integer()},
          dropped: %{String.t() => pos_integer()},
          error: String.t() | nil,
          disk: String.t() | nil,
          folders: [Path.t()]
        }

  @doc """
  Starts a recording in `:dir`, created if missing in its parent folder,
  which must exist.

  Options:
    * `:dir` - the recording's folder
    * `:name` - its files' names before `_<n>.mcap`
    * `:start_time_ns` - the recording's start on its messages' clock, the attachments' time
    * `:compression` - `:zstd` or `:none`, its chunks' (`:zstd`)
    * `:max_file_bytes` - the size past which a file is closed (`2_000_000_000`)
    * `:buffer_bytes` - the payload bytes held for this process to write (64 MiB)
    * `:attachments` - `{name, media_type, data}` attached to the first file (`[]`)
    * `:metadata` - string keys and values for the first file and `metadata.yaml` (`%{}`)
    * `:chunk_interval_ms` - the longest a chunk spans, in log time and since its
      first message (`1_000`)
    * `:disks` - the `VisionCore.Disks` to go on on, none by default
    * `:disk` - the UUID of the disk `:dir` is on
    * `:free_floor_bytes` - the free bytes below which a disk is left (`1_000_000_000`)
    * `:drain_ms` - the longest a stop writes what the buffer holds, below `stop/1`'s
      30 s wait so that the files close within it (`20_000`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, @options)
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Hands the recording `message`, of `message_module`, on `topic` at
  `log_time_ns`; dropped and counted past `:buffer_bytes` held.
  """
  @spec write(pid(), String.t(), module(), struct(), non_neg_integer()) :: :ok
  def write(server, topic, message_module, message, log_time_ns) do
    topic = Ros2Zenoh.full_name(topic)

    case :persistent_term.get({__MODULE__, server}, nil) do
      nil -> :ok
      intake -> buffer_or_drop(intake, topic, message_module, message, log_time_ns)
    end

    :ok
  end

  @doc false
  @spec write_encoded(pid(), Buffer.message()) :: :ok
  def write_encoded(server, message), do: GenServer.cast(server, {:write, message})

  @doc """
  The bytes written to the files, the files begun, the messages written and
  dropped per topic, why the recording ended early, if it did, the disk
  in use and the folder of each part; `nil` once the process has stopped.
  """
  @spec status(pid()) :: status() | nil
  def status(server) do
    case :persistent_term.get({__MODULE__, server}, nil) do
      nil -> nil
      {table, _buffer} -> read_status(table)
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
    dir = Keyword.fetch!(opts, :dir)
    disk = Keyword.fetch!(opts, :disk)

    :ets.insert(table, [{:bytes, 0}, {:files, 0}, {:error, nil}, {:disk, disk}, {:folders, [dir]}])

    {:ok, buffer} = Buffer.start_link(self(), Keyword.fetch!(opts, :buffer_bytes))
    :persistent_term.put({__MODULE__, self()}, {table, buffer})

    state = %{
      dir: dir,
      name: Keyword.fetch!(opts, :name),
      part: 1,
      part_name: Keyword.fetch!(opts, :name),
      folders: [dir],
      disks: Keyword.fetch!(opts, :disks),
      disk: disk,
      left_disks: [],
      dropped_before: %{},
      free_floor_bytes: Keyword.fetch!(opts, :free_floor_bytes),
      compression: Keyword.fetch!(opts, :compression),
      max_file_bytes: Keyword.fetch!(opts, :max_file_bytes),
      chunk_interval_ms: Keyword.fetch!(opts, :chunk_interval_ms),
      drain_ms: Keyword.fetch!(opts, :drain_ms),
      attachments: Keyword.fetch!(opts, :attachments),
      start_time_ns: Keyword.fetch!(opts, :start_time_ns),
      metadata: Keyword.fetch!(opts, :metadata),
      table: table,
      buffer: buffer,
      writer: nil,
      files: [],
      closed_bytes: 0,
      schemas: %{},
      channels: %{},
      topics: %{},
      last_log_time: 0,
      open_chunk: nil,
      ended: false
    }

    {:ok, state |> attempt_or_end(&open_folder/1) |> schedule_tick()}
  end

  @impl GenServer
  def handle_cast({:write, {topic, module, payload, log_time}}, state) do
    state = write_payload(state, topic, module, payload, log_time)
    Buffer.written(state.buffer)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, close(state)}

  @impl GenServer
  def handle_info(:tick, %{ended: true} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state =
      state
      |> check_disk()
      |> attempt_or_leave_disk([&flush_due(&1, &1.last_log_time), &close_file_if_full/1])

    {:noreply, schedule_tick(state)}
  end

  def handle_info({:EXIT, pid, reason}, %{buffer: %Buffer{pid: pid}} = state),
    do: {:stop, {:buffer_exited, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    close(state)
    :persistent_term.erase({__MODULE__, self()})
  end

  defp buffer_or_drop({table, buffer}, topic, module, message, log_time) do
    case encode(message) do
      {:ok, payload} ->
        if Buffer.put(buffer, topic, module, payload, log_time) == :full,
          do: count_drop(table, topic)

      {:error, reason} ->
        count_drop(table, topic)
        log_unencodable(table, topic, module, reason)
    end
  end

  defp write_payload(%{ended: true} = state, topic, _module, _payload, _log_time) do
    count_drop(state.table, topic)
    state
  end

  defp write_payload(state, topic, module, payload, log_time),
    do: attempt_or_leave_disk(state, write_steps(state, topic, module, payload, log_time))

  defp close(state), do: state |> write_held() |> finish()

  defp write_held(%{buffer: nil} = state), do: state

  defp write_held(state) do
    deadline_ms = now_ms() + state.drain_ms

    state.buffer
    |> Buffer.close()
    |> Enum.reduce(%{state | buffer: nil}, &write_before(&2, &1, deadline_ms))
  end

  defp write_before(state, {topic, module, payload, log_time}, deadline_ms) do
    if now_ms() < deadline_ms do
      write_payload(state, topic, module, payload, log_time)
    else
      count_drop(state.table, topic)
      state
    end
  end

  # A write's steps, each one write to the disk: one the disk refuses is the only one redone.
  defp write_steps(state, topic, module, payload, log_time) do
    clamped = max(log_time, state.last_log_time)

    [
      &flush_due(&1, clamped),
      &close_file_if_full/1,
      &ensure_file/1,
      &ensure_channel(&1, topic, module),
      &write_message(&1, topic, module, payload, log_time)
    ]
  end

  defp write_message(state, topic, module, payload, log_time) do
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
        open_chunk: count_in_chunk(state.open_chunk, topic, clamped)
    }
  end

  defp count_in_chunk(nil, topic, log_time),
    do: %{first_log_time: log_time, opened_ms: now_ms(), messages: %{topic => 1}}

  defp count_in_chunk(chunk, topic, _log_time),
    do: %{chunk | messages: Map.update(chunk.messages, topic, 1, &(&1 + 1))}

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

  defp open_folder(state) do
    case File.mkdir(state.dir) do
      made when made in [:ok, {:error, :eexist}] ->
        open_file(state)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory", path: state.dir
    end
  end

  defp open_file(state) do
    index = length(state.files)
    file_name = "#{state.part_name}_#{index}.mcap"
    path = Path.join(state.dir, file_name)

    writer =
      case Writer.open(path, compression: state.compression) do
        {:ok, writer} -> writer
        {:error, reason} -> raise File.Error, reason: reason, action: "open", path: path
      end

    writer =
      if index == 0,
        do:
          on_refusal(
            fn -> add_attachments_and_metadata(writer, state) end,
            fn -> Writer.abandon(writer) end
          ),
        else: writer

    state = %{
      state
      | writer: writer,
        files: [
          %{path: file_name, starting_time: nil, end_time: nil, message_count: 0} | state.files
        ],
        schemas: %{},
        channels: %{}
    }

    state = on_refusal(fn -> write_metadata_file(state) end, fn -> Writer.close(writer) end)
    :ets.update_counter(state.table, :files, 1)
    :ets.insert(state.table, [{:disk, state.disk}, {:folders, state.folders}])
    put_bytes(state)
  end

  # Runs `write`; the disk refusing it, `close` closes the file just opened.
  defp on_refusal(write, close) do
    write.()
  rescue
    error in File.Error ->
      close.()
      reraise error, __STACKTRACE__
  end

  defp add_attachments_and_metadata(writer, state) do
    time = state.start_time_ns

    writer =
      Enum.reduce(state.attachments, writer, fn {name, media_type, contents}, writer ->
        Writer.add_attachment(writer, name, media_type, time, time, contents)
      end)

    if state.metadata == %{},
      do: writer,
      else: Writer.add_metadata(writer, "recording", state.metadata)
  end

  # The open chunk spans the interval with a message at `log_time`, or has been open that long.
  defp chunk_due?(%{open_chunk: nil}, _log_time), do: false

  defp chunk_due?(%{open_chunk: chunk, chunk_interval_ms: interval_ms}, log_time) do
    log_time - chunk.first_log_time >= interval_ms * 1_000_000 or
      now_ms() - chunk.opened_ms >= interval_ms
  end

  defp flush_due(state, log_time),
    do: if(chunk_due?(state, log_time), do: flush(state), else: state)

  # Closes the open chunk and syncs it.
  defp flush(state) do
    writer = state.writer |> Writer.close_chunk() |> Writer.sync()
    put_bytes(%{state | writer: writer, open_chunk: nil})
  end

  # Closes a file past its size once its messages are flushed.
  defp close_file_if_full(%{writer: nil} = state), do: state

  defp close_file_if_full(state) do
    [file | _files] = state.files

    if state.open_chunk == nil and file.message_count > 0 and
         Writer.bytes_written(state.writer) >= state.max_file_bytes,
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

    put_bytes(%{state | writer: nil, closed_bytes: state.closed_bytes + size, open_chunk: nil})
  end

  defp put_bytes(state) do
    open_bytes = if state.writer, do: Writer.bytes_written(state.writer), else: 0
    :ets.insert(state.table, {:bytes, state.closed_bytes + open_bytes})
    state
  end

  defp finish(%{ended: true} = state), do: state

  defp finish(state) do
    state = attempt_or_end(state, [&close_open_file/1, &write_metadata_file/1])
    %{state | ended: true}
  end

  defp close_open_file(%{writer: nil} = state), do: state
  defp close_open_file(state), do: close_file(state)

  # Runs each step on the state the one before left; one the disk refuses ends the recording.
  defp attempt_or_end(state, steps) when is_list(steps),
    do: Enum.reduce(steps, state, &attempt_or_end(&2, &1))

  defp attempt_or_end(%{ended: true} = state, _step), do: state

  defp attempt_or_end(state, step) do
    step.(state)
  rescue
    error in File.Error ->
      state |> abandon_file() |> end_recording(Exception.message(error))
  end

  # Runs each step on the state the one before left; one the disk refuses again on the next disk.
  defp attempt_or_leave_disk(state, steps) when is_list(steps),
    do: Enum.reduce(steps, state, &attempt_or_leave_disk(&2, &1))

  defp attempt_or_leave_disk(%{ended: true} = state, _step), do: state

  defp attempt_or_leave_disk(state, step) do
    step.(state)
  rescue
    error in File.Error ->
      case state |> abandon_file() |> leave_disk(Exception.message(error)) do
        %{ended: true} = state -> state
        state -> attempt_or_leave_disk(state, step)
      end
  end

  defp check_disk(%{disks: nil} = state), do: state

  defp check_disk(state) do
    case Disks.fetch(state.disks, state.disk) do
      {:ok, disk} ->
        if Disk.writable?(disk, state.free_floor_bytes),
          do: state,
          else: leave_disk(state, leaving_reason(disk, state.free_floor_bytes))

      :error ->
        state
    end
  end

  defp leaving_reason(%Disk{state: :mounted, free_bytes: nil} = disk, _free_floor_bytes),
    do: "the free space of #{disk.uuid} is unknown"

  defp leaving_reason(%Disk{state: :mounted} = disk, free_floor_bytes),
    do: "#{disk.uuid} has #{disk.free_bytes} bytes free, below #{free_floor_bytes}"

  defp leaving_reason(%Disk{} = disk, _free_floor_bytes), do: "#{disk.uuid} is #{disk.state}"

  defp leave_disk(%{disks: nil} = state, reason), do: end_recording(state, reason)

  # The drops counted once, the part's until now and the next part's after.
  defp leave_disk(state, reason) do
    drops = drops(state.table)
    state |> close_part_on_leaving(drops) |> go_on(reason, drops)
  end

  defp go_on(state, reason, drops) do
    left = [state.disk | state.left_disks]

    case Disks.next(state.disks, state.free_floor_bytes, left) do
      {:ok, disk} ->
        Logger.warning(
          "#{inspect(__MODULE__)} #{state.dir}: #{reason}; the recording goes on on #{disk.uuid}"
        )

        start_part(%{state | left_disks: left}, disk, drops)

      {:error, no_disk} ->
        end_recording(state, "#{reason}; #{no_disk}")
    end
  end

  # Closes the part as far as the disk allows.
  defp close_part_on_leaving(state, drops),
    do: state |> close_file_or_lose_chunk() |> write_metadata_file_if_allowed(drops)

  defp write_metadata_file_if_allowed(state, drops) do
    write_metadata_file(state, drops)
  rescue
    _error in File.Error -> state
  end

  # A file the disk refuses to close is closed all the same, its open chunk lost.
  defp close_file_or_lose_chunk(%{writer: nil} = state), do: state

  defp close_file_or_lose_chunk(state) do
    close_file(state)
  rescue
    _error in File.Error -> lose_open_chunk(%{state | writer: nil})
  end

  # A refused step's writer may not hold what reached the file: its open chunk is lost.
  defp abandon_file(%{writer: nil} = state), do: state

  defp abandon_file(state) do
    Writer.abandon(state.writer)
    lose_open_chunk(%{state | writer: nil})
  end

  # Uncounts the open chunk's messages, which the disk did not take.
  defp lose_open_chunk(%{open_chunk: nil} = state), do: state

  defp lose_open_chunk(%{open_chunk: chunk} = state) do
    for {topic, count} <- chunk.messages, do: uncount_messages(state.table, topic, count)

    [file | files] = state.files
    lost = chunk.messages |> Map.values() |> Enum.sum()

    topics =
      Enum.reduce(chunk.messages, state.topics, fn {topic, count}, topics ->
        update_in(topics[topic].message_count, &(&1 - count))
      end)

    %{
      state
      | open_chunk: nil,
        topics: topics,
        files: [%{file | message_count: file.message_count - lost} | files]
    }
  end

  defp uncount_messages(table, topic, count) do
    if :ets.update_counter(table, {:messages, topic}, -count) == 0,
      do: :ets.delete(table, {:messages, topic})
  end

  defp start_part(state, disk, drops) do
    part = state.part + 1
    part_name = "#{state.name}_part#{part}"
    dir = Path.join(disk.recordings_path, part_name)

    case File.mkdir(dir) do
      :ok ->
        open_part(state, disk, part, part_name, dir, drops)

      {:error, reason} ->
        go_on(
          %{state | disk: disk.uuid},
          "cannot make #{dir}: #{:file.format_error(reason)}",
          drops
        )
    end
  end

  defp open_part(state, disk, part, part_name, dir, drops) do
    state = %{
      state
      | dir: dir,
        disk: disk.uuid,
        part: part,
        part_name: part_name,
        folders: state.folders ++ [dir],
        writer: nil,
        files: [],
        topics: %{},
        schemas: %{},
        channels: %{},
        dropped_before: drops,
        open_chunk: nil
    }

    attempt_or_leave_disk(state, &open_file/1)
  end

  defp end_recording(%{writer: nil} = state, reason) do
    Logger.error("#{inspect(__MODULE__)} #{state.dir}: #{reason}; the recording ends")
    state = %{state | ended: true}

    try do
      write_metadata_file(state)
    rescue
      _error in File.Error -> :ok
    end

    :ets.insert(state.table, {:error, reason})
    state
  end

  defp write_metadata_file(state), do: write_metadata_file(state, drops(state.table))

  # Writes metadata.yaml with the part's share of `drops`, the drops counted per topic.
  defp write_metadata_file(state, drops) do
    path = Path.join(state.dir, @metadata_file)
    temporary = path <> ".tmp"
    metadata = metadata(state, drops)

    with {:ok, file} <- :file.open(temporary, [:raw, :binary, :write]),
         :ok <- write_and_close(file, Metadata.encode(metadata)),
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

  defp metadata(state, drops) do
    drops =
      for {topic, count} <- drops,
          part_count = count - Map.get(state.dropped_before, topic, 0),
          part_count > 0,
          into: %{},
          do: {"dropped:" <> topic, Integer.to_string(part_count)}

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

  defp drops(table),
    do: for({{:dropped, topic}, count} <- :ets.tab2list(table), into: %{}, do: {topic, count})

  defp read_status(table) do
    entries = :ets.tab2list(table)

    %{
      bytes: :ets.lookup_element(table, :bytes, 2),
      files: :ets.lookup_element(table, :files, 2),
      messages: for({{:messages, topic}, count} <- entries, into: %{}, do: {topic, count}),
      dropped: drops(table),
      error: :ets.lookup_element(table, :error, 2),
      disk: :ets.lookup_element(table, :disk, 2),
      folders: :ets.lookup_element(table, :folders, 2)
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

  # Logs a topic's first message that does not encode.
  defp log_unencodable(table, topic, module, reason) do
    if :ets.insert_new(table, {{:unencodable, topic}}) do
      Logger.warning(
        "#{inspect(__MODULE__)} cannot encode #{inspect(module)} for #{topic}: #{reason}; " <>
          "dropping it; further failures are counted, not logged"
      )
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp type_hash(module) do
    Code.ensure_loaded(module)
    if function_exported?(module, :type_hash, 0), do: module.type_hash(), else: ""
  end

  defp schedule_tick(%{ended: true} = state), do: state

  defp schedule_tick(state) do
    delay =
      case state.open_chunk do
        nil -> state.chunk_interval_ms
        chunk -> max(chunk.opened_ms + state.chunk_interval_ms - now_ms(), 0)
      end

    Process.send_after(self(), :tick, delay)
    state
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
