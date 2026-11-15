defmodule VisionCore.Disks do
  @moduledoc """
  The disks recordings go on (`VisionCore.Disk`), in the order they are
  filled: the unit's own storage, `internal`, and the USB disks it has
  seen, each kept by its filesystem's UUID as a `VisionCore.Models.Disk`,
  so the order and the disks turned off survive unplugging and a reboot.
  A new disk goes last, turned on.

  Every `:poll_interval_ms` it lists the partitions of the disks in
  `/sys/block/sd*` on a USB bus, whose sysfs device is under a `usb<n>`,
  or a disk without partitions whole, and reads each
  new one's superblock (`VisionCore.Disk.identify/1`): an f2fs or ext4
  filesystem is mounted at `<mount_root>/<uuid>` with `noatime`,
  `nosymfollow`, `nodev`, `nosuid` and `noexec`, its recordings in the
  folder `recordings/` there; another is listed as unusable. A disk
  whose `recordings` is a link or a file is unmounted again and listed
  as unusable. A disk already mounted, found in `/proc/mounts` by its
  device, is taken as it is, and never formatted. A disk pulled out is
  unmounted lazily and listed as unplugged; a device whose disk's
  `diskseq`, or size, changed between two looks was pulled out and
  another plugged in. Then it reads each mounted disk's free bytes with
  `df`.

  `list/1`, `fetch/2` and `next/3` read a table this process keeps, so
  they answer while it mounts. `mkfs.f2fs` runs in a task, so the disks
  are watched and set while one formats. Without the database the disks
  are still found, mounted and chosen; only `put_order/2` and
  `put_enabled/3` answer an error. It saves nothing until it has read
  the saved disks, which it tries again at each look, so a database
  that starts late keeps the order it holds.

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
  # No access time written, and no link followed, device opened, setuid or program run off a disk.
  @mount_options "noatime,nosymfollow,nodev,nosuid,noexec"

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
  mounted, f2fs labelled `label` (`mkfs.f2fs -f -l`), listed as
  `:formatting` meanwhile. It answers once `mkfs.f2fs` ends, and the
  device is read again at the next look at the disks: a new disk,
  mounted. A device whose superblock no longer reads as the disk listed
  is not formatted.
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
        disks: %{},
        loaded: false,
        unusable: %{},
        formats: %{},
        devices: %{},
        mount_points: %{},
        ejecting: %{}
      }
      |> load_saved()
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

  def handle_call({:format, device, label}, from, state) do
    with :ok <- check_label(label),
         :ok <- check_formattable(state, device) do
      {:noreply, start_format(state, device, label, from)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  def handle_info({reference, answer}, state) when is_map_key(state.formats, reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, end_format(state, reference, answer)}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state)
      when is_map_key(state.formats, reference),
      do:
        {:noreply,
         end_format(state, reference, {:error, "mkfs.f2fs stopped: #{inspect(reason)}"})}

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
    state = if state.loaded, do: state, else: load_saved_again(state)
    state = if state.options.usb, do: watch_usb(state), else: state
    Process.send_after(self(), :poll, state.options.poll_interval_ms)
    state |> refresh_free_bytes() |> publish()
  end

  defp watch_usb(state) do
    present = scan(state.options.block_devices_path)
    state = Enum.reduce(replaced(state, present), state, &pull_out(&2, &1))

    present
    |> Map.drop(Map.keys(state.devices))
    |> Map.drop(for {_reference, format} <- state.formats, do: format.disk.device)
    |> Enum.sort()
    |> Enum.reduce(state, fn {device, block}, state -> plug_in(state, device, block) end)
  end

  # The devices gone, or another disk under the same name: its diskseq or size changed.
  defp replaced(state, present),
    do: for({device, seen} <- state.devices, present[device] != seen.block, do: device)

  # Each USB disk's partitions, or the disk whole without any, with its size and diskseq.
  defp scan(block_devices_path) do
    block_devices_path
    |> Path.join("sd*")
    |> Path.wildcard()
    |> Enum.filter(&usb?/1)
    |> Enum.flat_map(fn disk ->
      diskseq =
        case read_integer(Path.join(disk, "diskseq")) do
          {:ok, diskseq} -> diskseq
          :error -> nil
        end

      for path <- partitions_or_disk(disk),
          {:ok, sectors} <- [read_integer(Path.join(path, "size"))],
          do: {Path.basename(path), %{size_bytes: sectors * @sector_bytes, diskseq: diskseq}}
    end)
    |> Map.new()
  end

  defp partitions_or_disk(disk) do
    case Path.wildcard(Path.join(disk, Path.basename(disk) <> "*")) do
      [] -> [disk]
      partitions -> partitions
    end
  end

  # A disk under a USB bus, `usb<n>`: a USB SSD's enclosure does not set `removable`.
  defp usb?(disk) do
    case File.read_link(disk) do
      {:ok, target} -> target |> Path.split() |> Enum.any?(&Regex.match?(~r/^usb\d+$/, &1))
      {:error, _not_a_link} -> false
    end
  end

  defp read_integer(path) do
    with {:ok, text} <- File.read(path),
         {integer, _rest} <- Integer.parse(text) do
      {:ok, integer}
    else
      _unreadable -> :error
    end
  end

  # Holds `device` as seen: its block's size and diskseq, and the identity read now.
  defp plug_in(state, device, block) do
    identity = Disk.read_identity(device_path(state, device))
    seen = %{block: block, identity: identity, uuid: nil}
    state = %{state | devices: Map.put(state.devices, device, seen)}

    case identity do
      {:ok, identity} ->
        plug_in_known(state, device, block.size_bytes, identity)

      {:error, problem} ->
        put_unusable(state, device, block.size_bytes, problem)
    end
  end

  defp plug_in_known(state, device, size_bytes, identity) do
    case Enum.find(state.devices, fn {_device, seen} -> seen.uuid == identity.uuid end) do
      {other, _seen} ->
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

        save(state, [disk])
        state = put_in(state.devices[device].uuid, identity.uuid)
        mount(state, disk)
    end
  end

  defp put_unusable(state, device, size_bytes, problem) do
    Logger.warning("#{inspect(__MODULE__)} #{device} is not used: #{problem}")
    disk = %Disk{device: device, size_bytes: size_bytes, state: :unusable, problem: problem}
    %{state | unusable: Map.put(state.unusable, device, disk)}
  end

  defp new_disk(state, uuid), do: %Disk{uuid: uuid, position: next_position(state)}

  defp next_position(state) do
    case Map.values(state.disks) do
      [] -> 0
      disks -> 1 + Enum.max_by(disks, & &1.position).position
    end
  end

  defp mount(state, disk) do
    case mount_point(state, disk, device_path(state, disk.device)) do
      {:ok, mount_point, mounted_by} ->
        use_recordings_folder(state, disk, mount_point, mounted_by)

      {:error, problem} ->
        not_mounted(state, disk, problem)
    end
  end

  defp use_recordings_folder(state, disk, mount_point, mounted_by) do
    recordings = Path.join(mount_point, "recordings")

    case make_recordings_folder(recordings) do
      :ok ->
        Logger.info(
          "#{inspect(__MODULE__)} #{disk.device} (#{disk.label}) mounted at #{mount_point}"
        )

        %{state | mount_points: Map.put(state.mount_points, disk.uuid, mount_point)}
        |> put_disk(%{disk | state: :mounted, recordings_path: recordings, problem: nil})

      {:error, problem} ->
        state |> unmount_unused(disk, mount_point, mounted_by) |> not_mounted(disk, problem)
    end
  end

  defp not_mounted(state, disk, problem) do
    Logger.warning("#{inspect(__MODULE__)} #{disk.device} (#{disk.uuid}) not mounted: #{problem}")
    put_disk(state, %{disk | state: :unusable, problem: problem})
  end

  # Where `device` is mounted, and whether by this process or before it looked.
  defp mount_point(state, disk, device) do
    case mounted_at(state, device) do
      {:ok, mount_point} ->
        {:ok, mount_point, :before}

      :error ->
        mount_point = Path.join(state.options.mount_root, disk.uuid)
        filesystem = Atom.to_string(disk.filesystem)

        with :ok <- make_folder(mount_point),
             :ok <-
               run(state, "mount", ["-t", filesystem, "-o", @mount_options, device, mount_point]),
             do: {:ok, mount_point, :here}
    end
  end

  # Unmounts a disk mounted here and not used; one that stays mounted is detached when pulled out.
  defp unmount_unused(state, _disk, _mount_point, :before), do: state

  defp unmount_unused(state, disk, mount_point, :here) do
    case run(state, "umount", [mount_point]) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("#{inspect(__MODULE__)} #{mount_point} stays mounted: #{reason}")
        %{state | mount_points: Map.put(state.mount_points, disk.uuid, mount_point)}
    end
  end

  # Makes the recordings folder if missing; a link is refused, as it could lead off the disk.
  defp make_recordings_folder(path) do
    with {:error, :eexist} <- File.mkdir(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      :ok
    else
      :ok -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, "#{path} is #{kind(type)}, not a folder"}
      {:error, reason} -> {:error, "cannot make #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp kind(:symlink), do: "a symbolic link"
  defp kind(:regular), do: "a file"
  defp kind(type), do: "a #{type}"

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
    {%{uuid: uuid}, devices} = Map.pop!(state.devices, device)
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
    save(state, [disk])
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
    case Map.fetch(state.devices, device) do
      {:ok, %{uuid: uuid}} ->
        if mounted?(state, uuid, device),
          do: {:error, "#{device} is mounted: eject it first"},
          else: :ok

      :error ->
        {:error, "#{device} is no USB disk plugged in"}
    end
  end

  # Whether the disk of `uuid` is mounted, or `device` is, by this process or another.
  defp mounted?(state, uuid, device) do
    match?(%Disk{state: mounted} when mounted in [:mounted, :ejecting], state.disks[uuid]) or
      mounted_at(state, device_path(state, device)) != :error
  end

  # Runs mkfs.f2fs in a task, the device forgotten: the next look after it reads it anew.
  defp start_format(state, device, label, from) do
    %{block: block, identity: identity} = state.devices[device]
    path = device_path(state, device)
    run = state.options.run
    task = Task.async(fn -> format_device(run, device, path, identity, label) end)
    disk = %Disk{device: device, label: label, size_bytes: block.size_bytes, state: :formatting}

    %{state | formats: Map.put(state.formats, task.ref, %{from: from, disk: disk})}
    |> forget(device)
    |> publish()
  end

  # Formats the device at `path` if it still holds the disk read as `identity`.
  defp format_device(run, device, path, identity, label) do
    if Disk.read_identity(path) == identity,
      do: run_with(run, "mkfs.f2fs", ["-f", "-l", label, path]),
      else: {:error, "#{device} holds another disk than the one listed: not formatted"}
  end

  defp end_format(state, reference, answer) do
    {%{from: from, disk: disk}, formats} = Map.pop!(state.formats, reference)

    case answer do
      :ok -> Logger.info("#{inspect(__MODULE__)} #{disk.device} formatted f2fs, #{disk.label}")
      {:error, reason} -> Logger.warning("#{inspect(__MODULE__)} #{disk.device}: #{reason}")
    end

    GenServer.reply(from, answer)
    publish(%{state | formats: formats})
  end

  # Drops what is known of `device`, so the next look at the disks reads it anew.
  defp forget(state, device) do
    {%{uuid: uuid}, devices} = Map.pop!(state.devices, device)
    state = %{state | devices: devices, unusable: Map.delete(state.unusable, device)}

    case state.disks do
      %{^uuid => disk} -> put_disk(state, unplugged(disk))
      _disks -> state
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

  defp run(state, command, arguments), do: run_with(state.options.run, command, arguments)

  defp run_with(run, command, arguments) do
    case run.(command, arguments) do
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
        save(state, [disk])
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
    formatting = for {_reference, format} <- state.formats, do: format.disk
    unusable = (Map.values(state.unusable) ++ formatting) |> Enum.sort_by(& &1.device)
    :ets.insert(state.table, {:disks, ordered(state) ++ unusable})
    state
  end

  # Takes the saved disks once readable; saving nothing before, it never overwrites them.
  defp load_saved(state) do
    case load() do
      {:ok, saved} -> take_saved(state, saved)
      {:error, reason} -> unavailable(reason, state)
    end
  end

  # As `load_saved/1`, its failure logged once, at the start.
  defp load_saved_again(state) do
    case load() do
      {:ok, saved} -> take_saved(state, saved)
      {:error, _reason} -> state
    end
  end

  # Disks seen before take their saved position and enabled; the others go after the saved ones.
  defp take_saved(state, saved) do
    saved = Map.new(saved, &{&1.uuid, &1})
    first_free = saved |> Map.values() |> Enum.map(& &1.position) |> Enum.max(fn -> -1 end)

    {known, unsaved} =
      state.disks |> Map.values() |> Enum.split_with(&Map.has_key?(saved, &1.uuid))

    known =
      for disk <- known,
          do: %{disk | position: saved[disk.uuid].position, enabled: saved[disk.uuid].enabled}

    unsaved =
      unsaved
      |> Enum.sort_by(&{&1.position, &1.uuid})
      |> Enum.with_index(first_free + 1)
      |> Enum.map(fn {disk, position} -> %{disk | position: position} end)

    disks = Map.new(Map.values(saved) ++ known ++ unsaved, &{&1.uuid, &1})
    state = %{state | loaded: true, disks: disks}
    save(state, unsaved)
    state
  end

  defp load do
    disks =
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

    {:ok, disks}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp filesystem("f2fs"), do: :f2fs
  defp filesystem("ext4"), do: :ext4
  defp filesystem(nil), do: nil

  # Saves `disks`, all or none, then holds them.
  defp save_all(state, disks) do
    case save(state, disks) do
      :ok ->
        state = Enum.reduce(disks, state, &put_disk(&2, &1))
        {:reply, :ok, publish(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp save(%{loaded: false}, _disks), do: {:error, @unavailable}
  defp save(_state, []), do: :ok

  defp save(_state, disks) do
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
