defmodule VisionCore.Disks do
  @moduledoc """
  The disks recordings go on (`VisionCore.Disk`), in the order they are
  filled: the unit's own storage, `internal`, and the USB disks it has
  seen, each kept by its filesystem's UUID as a `VisionCore.Models.Disk`,
  so the order and the disks turned off survive unplugging and a reboot.
  A new disk goes last, turned on.

  Every `:poll_interval_ms` it lists the USB disks' partitions in
  `/sys/block/sd*`, or a disk without partitions whole, and reads each
  new one's superblock (`VisionCore.Disk.identify/1`): an f2fs or ext4
  filesystem is mounted at `<mount_root>/<uuid>` with `noatime`, its
  recordings in `recordings/` there; another is listed as unusable. A
  disk already mounted, found in `/proc/mounts` by its device, is taken
  as it is. A disk pulled out is unmounted lazily and listed as
  unplugged. Then it reads each mounted disk's free bytes with `df`.

  `list/1`, `fetch/2` and `next/3` read a table this process keeps, so
  they answer while it mounts or formats. Without the database the disks
  are still found, mounted and chosen; only `put_order/2` and
  `put_enabled/3` answer an error.

  The bag exporter (`VisionCore.Ros2.BagExporter`) starts it as its
  helper. The USB disks are watched only in a target build
  (`VisionCore.arm/0`), so a run on a host never mounts its disks.

  ## Options

    * `:name` - its registered name (`VisionCore.Disks`), `nil` for none
    * `:internal` - the unit's storage's recordings folder (`"/data/recordings"`)
    * `:mount_root` - where USB disks are mounted (`"/data/disks"`)
    * `:usb` - whether USB disks are watched (in a target build)
    * `:block_devices_path`, `:devices_path`, `:mounts_path` - the
      system's `/sys/block`, `/dev` and `/proc/mounts`
    * `:poll_interval_ms` - the time between two looks at the disks (`2_000`)
    * `:eject_timeout_ms` - how long `eject/2` waits for a busy disk (`10_000`)
    * `:repo` - the `VisionCore.Repo` process the order is saved in (`VisionCore.Repo`)
    * `:run` - runs a command with its arguments, as `System.cmd/3`
      answers: `mount`, `umount`, `df` and `mkfs.f2fs`
  """
  use GenServer

  require Logger

  alias VisionCore.Disk
  alias VisionCore.Models
  alias VisionCore.Repo

  @internal "internal"
  @usb_watched VisionCore.arm() == :target
  @sector_bytes 512
  @kibibyte 1024
  @unmount_retry_ms 200
  @format_timeout_ms 300_000
  @f2fs_label_units 512
  @unavailable "the disks' order is unavailable"

  @doc "Starts watching the disks; see the module's options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, defaults())

    case Keyword.fetch!(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  defp defaults do
    [
      name: __MODULE__,
      internal: "/data/recordings",
      mount_root: "/data/disks",
      usb: @usb_watched,
      block_devices_path: "/sys/block",
      devices_path: "/dev",
      mounts_path: "/proc/mounts",
      poll_interval_ms: 2_000,
      eject_timeout_ms: 10_000,
      repo: Repo,
      run: &run_command/2
    ]
  end

  @doc "The disks in their order, then the unusable ones; `[]` when `server` is not running."
  @spec list(GenServer.server()) :: [Disk.t()]
  def list(server) do
    case table(server) do
      nil -> []
      table -> :ets.lookup_element(table, :disks, 2)
    end
  rescue
    ArgumentError -> []
  end

  @doc "The disk of `uuid`."
  @spec fetch(GenServer.server(), String.t()) :: {:ok, Disk.t()} | :error
  def fetch(server, uuid) do
    case Enum.find(list(server), &(&1.uuid == uuid)) do
      nil -> :error
      disk -> {:ok, disk}
    end
  end

  @doc """
  The first disk in the order that is mounted, turned on and has
  `free_floor_bytes` free, other than those of `except`.
  """
  @spec next(GenServer.server(), non_neg_integer(), [String.t()]) ::
          {:ok, Disk.t()} | {:error, String.t()}
  def next(server, free_floor_bytes, except \\ []) do
    case Enum.find(list(server), &chosen?(&1, free_floor_bytes, except)) do
      nil -> {:error, no_disk(free_floor_bytes, except)}
      disk -> {:ok, disk}
    end
  end

  defp chosen?(disk, free_floor_bytes, except),
    do: disk.enabled and disk.uuid not in except and Disk.writable?(disk, free_floor_bytes)

  defp no_disk(free_floor_bytes, []),
    do: "no disk is mounted, turned on and with #{free_floor_bytes} bytes free"

  defp no_disk(free_floor_bytes, except),
    do: no_disk(free_floor_bytes, []) <> " besides #{Enum.join(except, ", ")}"

  @doc """
  Puts the disks of `uuids` first, in that order, and the others after
  them in the order they had.
  """
  @spec put_order(GenServer.server(), [String.t()]) :: :ok | {:error, String.t()}
  def put_order(server, uuids), do: GenServer.call(server, {:put_order, uuids})

  @doc "Turns the disk of `uuid` on or off: a disk turned off is not chosen by `next/3`."
  @spec put_enabled(GenServer.server(), String.t(), boolean()) :: :ok | {:error, String.t()}
  def put_enabled(server, uuid, enabled) when is_boolean(enabled),
    do: GenServer.call(server, {:put_enabled, uuid, enabled})

  @doc """
  Unmounts the USB disk of `uuid`. It is `:ejecting` until then, so a
  recording on it closes its file and goes on on the next disk; an
  error when it stays busy past `:eject_timeout_ms`, mounted still. An
  ejected disk stays unmounted until it is plugged in again or this
  process restarts, as at the unit's restart.
  """
  @spec eject(GenServer.server(), String.t()) :: :ok | {:error, String.t()}
  def eject(server, uuid), do: GenServer.call(server, {:eject, uuid}, :infinity)

  @doc """
  Makes `device`, a USB disk's partition such as `sda1` that is not
  mounted, f2fs labelled `label` (`mkfs.f2fs -f -l`). It is mounted at
  the next look at the disks, as a new disk.
  """
  @spec format(GenServer.server(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def format(server, device, label),
    do: GenServer.call(server, {:format, device, label}, @format_timeout_ms)

  @doc false
  @spec run_command(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def run_command(command, arguments) do
    System.cmd(command, arguments, stderr_to_stdout: true)
  rescue
    error in ErlangError -> {"#{command}: #{Exception.message(error)}", 127}
  end

  defp table(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> :persistent_term.get({__MODULE__, pid}, nil)
      _not_running -> nil
    end
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    Repo.put_dynamic_repo(Keyword.fetch!(opts, :repo))
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    :persistent_term.put({__MODULE__, self()}, table)

    state =
      %{
        options: Map.new(opts),
        table: table,
        disks: Map.new(load(), &{&1.uuid, &1}),
        unusable: %{},
        devices: %{},
        mount_points: %{},
        ejecting: %{}
      }
      |> remember_internal()
      |> refresh_free_bytes()
      |> publish()

    {:ok, state, {:continue, :poll}}
  end

  @impl GenServer
  def handle_continue(:poll, state), do: {:noreply, poll(state)}

  @impl GenServer
  def handle_call({:put_order, uuids}, _from, state) do
    case Enum.reject(uuids, &Map.has_key?(state.disks, &1)) do
      [] ->
        order = Enum.uniq(uuids ++ Enum.map(ordered(state), & &1.uuid))
        disks = order |> Enum.with_index() |> Enum.map(&put_position(state, &1))
        save_all(state, disks)

      unknown ->
        {:reply, {:error, "no disk #{Enum.join(unknown, ", ")} is known"}, state}
    end
  end

  def handle_call({:put_enabled, uuid, enabled}, _from, state) do
    case state.disks do
      %{^uuid => disk} -> save_all(state, [%{disk | enabled: enabled}])
      _disks -> {:reply, {:error, "no disk #{uuid} is known"}, state}
    end
  end

  def handle_call({:eject, @internal}, _from, state),
    do: {:reply, {:error, "the unit's storage is not ejected"}, state}

  def handle_call({:eject, uuid}, from, state) do
    case state.disks do
      %{^uuid => %Disk{state: :mounted} = disk} ->
        send(self(), {:unmount, uuid})
        deadline = now_ms() + state.options.eject_timeout_ms

        state =
          %{state | ejecting: Map.put(state.ejecting, uuid, {from, deadline})}
          |> put_disk(%{disk | state: :ejecting})
          |> publish()

        {:noreply, state}

      %{^uuid => _disk} ->
        {:reply, {:error, "#{uuid} is not mounted"}, state}

      _disks ->
        {:reply, {:error, "no disk #{uuid} is known"}, state}
    end
  end

  def handle_call({:format, device, label}, _from, state) do
    with :ok <- check_label(label),
         :ok <- check_formattable(state, device) do
      run_format(state, device, label)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  def handle_info({:unmount, uuid}, state) do
    case state.ejecting do
      %{^uuid => {from, deadline}} -> {:noreply, unmount(state, uuid, from, deadline)}
      _ejecting -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state), do: :persistent_term.erase({__MODULE__, self()})

  defp poll(state) do
    state = if state.options.usb, do: watch_usb(state), else: state
    Process.send_after(self(), :poll, state.options.poll_interval_ms)
    state |> refresh_free_bytes() |> publish()
  end

  defp watch_usb(state) do
    present = scan(state.options.block_devices_path)
    gone = Map.keys(state.devices) -- Map.keys(present)
    state = Enum.reduce(gone, state, &pull_out(&2, &1))

    present
    |> Map.drop(Map.keys(state.devices))
    |> Enum.sort()
    |> Enum.reduce(state, fn {device, size_bytes}, state -> plug_in(state, device, size_bytes) end)
  end

  # Each USB disk's partitions, or the disk itself without any, with its size.
  defp scan(block_devices_path) do
    block_devices_path
    |> Path.join("sd*")
    |> Path.wildcard()
    |> Enum.flat_map(fn disk ->
      case Path.wildcard(Path.join(disk, Path.basename(disk) <> "*")) do
        [] -> [disk]
        partitions -> partitions
      end
    end)
    |> Enum.flat_map(fn path ->
      case read_size(path) do
        {:ok, size_bytes} -> [{Path.basename(path), size_bytes}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp read_size(path) do
    with {:ok, text} <- File.read(Path.join(path, "size")),
         {sectors, _rest} <- Integer.parse(text) do
      {:ok, sectors * @sector_bytes}
    else
      _unreadable -> :error
    end
  end

  defp plug_in(state, device, size_bytes) do
    case Disk.read_identity(device_path(state, device)) do
      {:ok, identity} ->
        plug_in_known(state, device, size_bytes, identity)

      {:error, problem} ->
        put_unusable(state, device, size_bytes, problem)
    end
  end

  defp plug_in_known(state, device, size_bytes, identity) do
    case Enum.find(state.devices, fn {_device, uuid} -> uuid == identity.uuid end) do
      {other, _uuid} ->
        put_unusable(state, device, size_bytes, "#{other} has the same UUID, #{identity.uuid}")

      nil ->
        disk =
          state.disks
          |> Map.get_lazy(identity.uuid, fn -> new_disk(state, identity.uuid) end)
          |> Map.merge(%{
            label: identity.label,
            filesystem: identity.filesystem,
            device: device,
            size_bytes: size_bytes,
            last_seen_at: now()
          })

        save([disk])
        state = %{state | devices: Map.put(state.devices, device, identity.uuid)}
        mount(state, disk)
    end
  end

  defp put_unusable(state, device, size_bytes, problem) do
    Logger.warning("#{inspect(__MODULE__)} #{device} is not used: #{problem}")
    disk = %Disk{device: device, size_bytes: size_bytes, state: :unusable, problem: problem}

    %{
      state
      | devices: Map.put(state.devices, device, nil),
        unusable: Map.put(state.unusable, device, disk)
    }
  end

  defp new_disk(state, uuid), do: %Disk{uuid: uuid, position: next_position(state)}

  defp next_position(state) do
    case Map.values(state.disks) do
      [] -> 0
      disks -> 1 + Enum.max_by(disks, & &1.position).position
    end
  end

  defp mount(state, disk) do
    device = device_path(state, disk.device)

    with {:ok, mount_point} <- mount_point(state, disk, device),
         recordings = Path.join(mount_point, "recordings"),
         :ok <- make_folder(recordings) do
      Logger.info(
        "#{inspect(__MODULE__)} #{disk.device} (#{disk.label}) mounted at #{mount_point}"
      )

      %{state | mount_points: Map.put(state.mount_points, disk.uuid, mount_point)}
      |> put_disk(%{disk | state: :mounted, recordings_path: recordings, problem: nil})
    else
      {:error, problem} ->
        Logger.warning(
          "#{inspect(__MODULE__)} #{disk.device} (#{disk.uuid}) not mounted: #{problem}"
        )

        put_disk(state, %{disk | state: :unusable, problem: problem})
    end
  end

  defp mount_point(state, disk, device) do
    case mounted_at(state, device) do
      {:ok, mount_point} ->
        {:ok, mount_point}

      :error ->
        mount_point = Path.join(state.options.mount_root, disk.uuid)

        with :ok <- make_folder(mount_point),
             :ok <-
               run(state, "mount", [
                 "-t",
                 Atom.to_string(disk.filesystem),
                 "-o",
                 "noatime",
                 device,
                 mount_point
               ]),
             do: {:ok, mount_point}
    end
  end

  # Where `device` is mounted, from the mounts table.
  defp mounted_at(state, device) do
    with {:ok, mounts} <- File.read(state.options.mounts_path),
         [_device, mount_point | _rest] <-
           mounts
           |> String.split("\n", trim: true)
           |> Enum.map(&String.split/1)
           |> Enum.find(&match?([^device | _rest], &1)) do
      {:ok, String.replace(mount_point, "\\040", " ")}
    else
      _not_mounted -> :error
    end
  end

  defp make_folder(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot make #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp pull_out(state, device) do
    {uuid, devices} = Map.pop(state.devices, device)
    state = %{state | devices: devices, unusable: Map.delete(state.unusable, device)}

    case state.disks do
      %{^uuid => disk} -> unplug(state, disk)
      _disks -> state
    end
  end

  defp unplug(state, disk) do
    {mount_point, mount_points} = Map.pop(state.mount_points, disk.uuid)
    Logger.info("#{inspect(__MODULE__)} #{disk.device} (#{disk.label}) pulled out")
    if mount_point, do: detach(state, mount_point)

    {ejecting, others} = Map.pop(state.ejecting, disk.uuid)
    if ejecting, do: GenServer.reply(elem(ejecting, 0), :ok)

    disk = %{unplugged(disk) | last_seen_at: now()}
    save([disk])
    put_disk(%{state | mount_points: mount_points, ejecting: others}, disk)
  end

  defp detach(state, mount_point) do
    with {:error, reason} <- run(state, "umount", ["-l", mount_point]),
         do: Logger.warning("#{inspect(__MODULE__)} #{mount_point} stays mounted: #{reason}")
  end

  defp unplugged(disk),
    do: %{
      disk
      | state: :unplugged,
        device: nil,
        free_bytes: nil,
        recordings_path: nil,
        problem: nil
    }

  defp unmount(state, uuid, from, deadline) do
    disk = state.disks[uuid]
    mount_point = state.mount_points[uuid]

    case state.options.run.("umount", [mount_point]) do
      {_output, 0} ->
        Logger.info("#{inspect(__MODULE__)} #{disk.device} (#{disk.label}) ejected")
        ejected = %{disk | state: :ejected, free_bytes: nil, recordings_path: nil}

        %{
          state
          | ejecting: Map.delete(state.ejecting, uuid),
            mount_points: Map.delete(state.mount_points, uuid)
        }
        |> put_disk(ejected)
        |> publish()
        |> tap(fn _state -> GenServer.reply(from, :ok) end)

      {output, _status} ->
        if now_ms() < deadline do
          Process.send_after(self(), {:unmount, uuid}, @unmount_retry_ms)
          state
        else
          %{state | ejecting: Map.delete(state.ejecting, uuid)}
          |> put_disk(%{disk | state: :mounted})
          |> publish()
          |> tap(fn _state ->
            GenServer.reply(from, {:error, "#{uuid} stays busy: #{String.trim(output)}"})
          end)
        end
    end
  end

  defp check_label(label) do
    with true <- is_binary(label) and String.valid?(label) and not String.contains?(label, <<0>>),
         units = div(byte_size(:unicode.characters_to_binary(label, :utf8, {:utf16, :little})), 2),
         true <- units <= @f2fs_label_units do
      :ok
    else
      false -> {:error, "an f2fs label is text of at most #{@f2fs_label_units} characters"}
    end
  end

  defp check_formattable(state, device) do
    with {:ok, uuid} <- Map.fetch(state.devices, device),
         %Disk{state: mounted} when mounted in [:mounted, :ejecting] <- state.disks[uuid] do
      {:error, "#{device} is mounted: eject it first"}
    else
      :error -> {:error, "#{device} is no USB disk plugged in"}
      _not_mounted -> :ok
    end
  end

  defp run_format(state, device, label) do
    case run(state, "mkfs.f2fs", ["-f", "-l", label, device_path(state, device)]) do
      :ok ->
        Logger.info("#{inspect(__MODULE__)} #{device} formatted f2fs, #{label}")
        {uuid, devices} = Map.pop(state.devices, device)
        state = %{state | devices: devices, unusable: Map.delete(state.unusable, device)}

        state =
          case state.disks do
            %{^uuid => disk} -> put_disk(state, unplugged(disk))
            _disks -> state
          end

        {:reply, :ok, publish(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp refresh_free_bytes(state) do
    Enum.reduce(state.disks, state, fn
      {_uuid, %Disk{state: disk_state} = disk}, state when disk_state in [:mounted, :ejecting] ->
        put_disk(state, %{disk | free_bytes: free_bytes(state, disk)})

      {_uuid, _disk}, state ->
        state
    end)
  end

  # The free bytes `df -P -k` gives in its last line's fourth column, `nil` when it fails.
  defp free_bytes(state, disk) do
    with {output, 0} <- state.options.run.("df", ["-P", "-k", disk.recordings_path]),
         [_filesystem, _total, _used, available | _rest] <-
           output |> String.split("\n", trim: true) |> List.last("") |> String.split(),
         {kibibytes, ""} <- Integer.parse(available) do
      kibibytes * @kibibyte
    else
      _failed -> nil
    end
  end

  defp run(state, command, arguments) do
    case state.options.run.(command, arguments) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "#{command} failed (#{status}): #{String.trim(to_string(output))}"}
    end
  end

  defp device_path(state, device), do: Path.join(state.options.devices_path, device)

  defp remember_internal(state) do
    path = state.options.internal

    disk =
      Map.get_lazy(state.disks, @internal, fn ->
        disk = %{new_disk(state, @internal) | last_seen_at: now()}
        save([disk])
        disk
      end)

    case make_folder(path) do
      :ok ->
        put_disk(state, %{disk | state: :mounted, recordings_path: path})

      {:error, problem} ->
        Logger.warning("#{inspect(__MODULE__)} the unit's storage is not used: #{problem}")
        put_disk(state, %{disk | state: :unusable, problem: problem})
    end
  end

  defp put_disk(state, disk), do: %{state | disks: Map.put(state.disks, disk.uuid, disk)}

  defp put_position(state, {uuid, position}), do: %{state.disks[uuid] | position: position}

  defp ordered(state), do: Enum.sort_by(Map.values(state.disks), &{&1.position, &1.uuid})

  defp publish(state) do
    unusable = state.unusable |> Map.values() |> Enum.sort_by(& &1.device)
    :ets.insert(state.table, {:disks, ordered(state) ++ unusable})
    state
  end

  defp load do
    for row <- Repo.all(Models.Disk) do
      %Disk{
        uuid: row.uuid,
        label: row.label,
        filesystem: filesystem(row.filesystem),
        position: row.position,
        enabled: row.enabled,
        last_seen_at: row.last_seen_at
      }
    end
  rescue
    error -> unavailable(error, [])
  catch
    :exit, reason -> unavailable(reason, [])
  end

  defp filesystem("f2fs"), do: :f2fs
  defp filesystem("ext4"), do: :ext4
  defp filesystem(nil), do: nil

  # Saves `disks`, all or none, then holds them.
  defp save_all(state, disks) do
    case save(disks) do
      :ok ->
        state = Enum.reduce(disks, state, &put_disk(&2, &1))
        {:reply, :ok, publish(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp save(disks) do
    {:ok, :ok} = Repo.transaction(fn -> Enum.each(disks, &upsert/1) end)
    :ok
  rescue
    error -> unavailable(error, {:error, @unavailable})
  catch
    :exit, reason -> unavailable(reason, {:error, @unavailable})
  end

  defp upsert(disk) do
    %Models.Disk{}
    |> Models.Disk.changeset(%{
      uuid: disk.uuid,
      label: disk.label,
      filesystem: disk.filesystem && Atom.to_string(disk.filesystem),
      position: disk.position,
      enabled: disk.enabled,
      last_seen_at: disk.last_seen_at
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:label, :filesystem, :position, :enabled, :last_seen_at]},
      conflict_target: :uuid
    )
  end

  defp unavailable(reason, answer) do
    Logger.warning("#{@unavailable}: #{inspect(reason)}")
    answer
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
