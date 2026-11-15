defmodule VisionCore.TestDisks do
  @moduledoc """
  A `VisionCore.Disks` on a fake system under a test's folder: `sys/block`,
  `dev`, a `mounts` file, the unit's storage `recordings`, mount points
  under `disks`, and commands that change those files as `mount`,
  `umount` and `mkfs.f2fs` would. Each has a database of its own, in
  memory.

  A plugged device's file holds the superblock `f2fs_image/2` or
  `ext4_image/2` builds. `df` answers the free bytes `put_free/3` set,
  10 GB by default; `umount` answers busy while `hold_busy/2` says so.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 2]

  alias VisionCore.{Disks, Repo}

  @default_free_bytes 10_000_000_000
  @sector_bytes 512

  defstruct [:dir, :options, :system, :server, :id, :repo]

  @type t :: %__MODULE__{}

  @doc "The fake system in `dir` and a database, without a `Disks` yet."
  @spec setup!(Path.t()) :: t()
  def setup!(dir) do
    File.mkdir_p!(dir)
    repo = start_repo!()
    mounts = Path.join(dir, "mounts")
    File.write!(mounts, "")

    system =
      start_supervised!({Agent, fn -> %{free: %{}, busy: false, commands: [], diskseq: 0} end},
        id: make_ref()
      )

    options = [
      name: nil,
      internal: Path.join(dir, "recordings"),
      mount_root: Path.join(dir, "disks"),
      block_devices_path: Path.join(dir, "sys/block"),
      devices_path: Path.join(dir, "dev"),
      mounts_path: mounts,
      poll_interval_ms: 10,
      repo: repo,
      run: &run(system, mounts, &1, &2)
    ]

    File.mkdir_p!(options[:block_devices_path])
    File.mkdir_p!(options[:devices_path])
    %__MODULE__{dir: dir, options: options, system: system, repo: repo}
  end

  @doc "Starts its `Disks`, watching USB disks, with `extra` options."
  @spec start!(t(), keyword()) :: t()
  def start!(%__MODULE__{} = disks, extra \\ []) do
    options = Keyword.merge(disks.options ++ [usb: true], extra)
    id = make_ref()
    %{disks | server: start_supervised!({Disks, options}, id: id), id: id}
  end

  @doc "Stops its `Disks`."
  @spec stop!(t()) :: :ok
  def stop!(%__MODULE__{id: id}), do: ExUnit.Callbacks.stop_supervised!(id)

  @doc """
  A database, migrated: fresh and in memory by default, or the file
  `:database`, under `:name`, supervised as `:id`.
  """
  @spec start_repo!(keyword()) :: pid()
  def start_repo!(opts \\ []) do
    {id, opts} =
      opts
      |> Keyword.validate!(name: nil, database: ":memory:", id: make_ref())
      |> Keyword.pop!(:id)

    repo = start_supervised!({Repo, opts ++ [pool_size: 1, log: false]}, id: id)

    Ecto.Migrator.run(Repo, migrations(), :up, all: true, dynamic_repo: repo, log: false)
    repo
  end

  # The migrations test_helper.exs compiled, by version: compiling their files again redefines them.
  defp migrations do
    for path <- Path.wildcard("priv/repo/migrations/*.exs") do
      [version, name] = path |> Path.basename(".exs") |> String.split("_", parts: 2)
      {String.to_integer(version), Module.concat(Repo.Migrations, Macro.camelize(name))}
    end
  end

  @doc """
  Plugs `device`, a partition such as `sda1` or a whole disk such as
  `sdb`, holding `image`, of `size_bytes`. Its disk's `/sys/block` entry
  links to a device on a USB bus, or on `bus: :ata`, with the next
  `diskseq`.
  """
  @spec plug(t(), String.t(), binary(), pos_integer(), keyword()) :: :ok
  def plug(%__MODULE__{} = disks, device, image, size_bytes \\ 64_000_000_000, opts \\ []) do
    opts = Keyword.validate!(opts, bus: :usb)
    File.write!(device_path(disks, device), image)
    [parent] = Regex.run(~r/^sd[a-z]+/, device)
    disk = disk_directory(disks, parent, Keyword.fetch!(opts, :bus))

    block =
      case Regex.run(~r/^sd[a-z]+(\d+)$/, device) do
        [_device, number] ->
          block = Path.join(disk, device)
          File.mkdir_p!(block)
          File.write!(Path.join(block, "partition"), number <> "\n")
          block

        nil ->
          disk
      end

    File.write!(Path.join(block, "size"), "#{div(size_bytes, @sector_bytes)}\n")
  end

  # The disk's sysfs folder, with its diskseq, and its `/sys/block` link, made the first time.
  defp disk_directory(disks, parent, bus) do
    link = Path.join(disks.options[:block_devices_path], parent)
    target = Path.join(["..", "devices", bus_path(bus), "block", parent])
    disk = Path.expand(target, disks.options[:block_devices_path])

    unless File.dir?(disk) do
      File.mkdir_p!(disk)

      diskseq =
        Agent.get_and_update(disks.system, &{&1.diskseq + 1, %{&1 | diskseq: &1.diskseq + 1}})

      File.write!(Path.join(disk, "diskseq"), "#{diskseq}\n")
      File.ln_s!(target, link)
    end

    disk
  end

  defp bus_path(:usb), do: "platform/soc/xhci-hcd.0/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0"
  defp bus_path(:ata), do: "platform/soc/ahci.0/ata1/host0/target0:0:0/0:0:0:0"

  @doc "Pulls out the disk holding `device`, with all its partitions."
  @spec pull(t(), String.t()) :: :ok
  def pull(%__MODULE__{} = disks, device) do
    [parent] = Regex.run(~r/^sd[a-z]+/, device)
    link = Path.join(disks.options[:block_devices_path], parent)
    {:ok, target} = File.read_link(link)
    File.rm_rf!(Path.expand(target, disks.options[:block_devices_path]))
    File.rm!(link)

    for path <- Path.wildcard(Path.join(disks.options[:devices_path], parent <> "*")),
        do: File.rm!(path)

    :ok
  end

  @doc "The file standing for `device`."
  @spec device_path(t(), String.t()) :: Path.t()
  def device_path(%__MODULE__{} = disks, device),
    do: Path.join(disks.options[:devices_path], device)

  @doc "Where the disk of `uuid` is mounted."
  @spec mount_point(t(), String.t()) :: Path.t()
  def mount_point(%__MODULE__{} = disks, uuid), do: Path.join(disks.options[:mount_root], uuid)

  @doc "Makes `df` answer `free_bytes` for `path` and the folders in it."
  @spec put_free(t(), Path.t(), non_neg_integer()) :: :ok
  def put_free(%__MODULE__{system: system}, path, free_bytes),
    do: Agent.update(system, &put_in(&1, [:free, path], free_bytes))

  @doc "Makes `umount` answer busy, or not."
  @spec hold_busy(t(), boolean()) :: :ok
  def hold_busy(%__MODULE__{system: system}, busy?),
    do: Agent.update(system, &%{&1 | busy: busy?})

  @doc "The commands run, in order, each `{command, arguments}`."
  @spec commands(t()) :: [{String.t(), [String.t()]}]
  def commands(%__MODULE__{system: system}),
    do: system |> Agent.get(& &1.commands) |> Enum.reverse()

  @doc "The commands run named `command`, in order."
  @spec commands(t(), String.t()) :: [[String.t()]]
  def commands(%__MODULE__{} = disks, command),
    do: for({^command, arguments} <- commands(disks), do: arguments)

  @doc "An f2fs superblock, as the first 4 KiB of its partition."
  @spec f2fs_image(String.t(), String.t()) :: binary()
  def f2fs_image(uuid, label) do
    label = :unicode.characters_to_binary(label, :utf8, {:utf16, :little})

    image(
      <<0::size(1024 * 8), 0xF2F52010::little-32, 0::size(104 * 8), uuid_bytes(uuid)::binary,
        label::binary>>
    )
  end

  @doc "An ext4 superblock, as the first 4 KiB of its partition."
  @spec ext4_image(String.t(), String.t()) :: binary()
  def ext4_image(uuid, label) do
    image(
      <<0::size(1080 * 8), 0xEF53::little-16, 0::size(46 * 8), uuid_bytes(uuid)::binary,
        label::binary>>
    )
  end

  @doc "4 KiB of no filesystem."
  @spec blank_image() :: binary()
  def blank_image, do: image(<<>>)

  defp image(head), do: head <> :binary.copy(<<0>>, 4096 - byte_size(head))

  defp uuid_bytes(uuid), do: uuid |> String.replace("-", "") |> Base.decode16!(case: :lower)

  defp run(system, mounts, command, arguments) do
    Agent.update(system, &%{&1 | commands: [{command, arguments} | &1.commands]})
    answer(system, mounts, command, arguments)
  end

  defp answer(system, _mounts, "df", ["-P", "-k", path]) do
    free_kib = div(free_bytes(system, path), 1024)

    {"Filesystem 1024-blocks Used Available Capacity Mounted on\n" <>
       "/dev/fake #{free_kib + 1000} 1000 #{free_kib} 1% #{path}\n", 0}
  end

  defp answer(_system, mounts, "mount", ["-t", filesystem, "-o", options, device, point]) do
    File.write!(mounts, "#{device} #{point} #{filesystem} rw,#{options} 0 0\n", [:append])
    {"", 0}
  end

  defp answer(_system, mounts, "umount", ["-l", point]), do: unmount(mounts, point)

  defp answer(system, mounts, "umount", [point]) do
    if Agent.get(system, & &1.busy),
      do: {"umount: can't unmount #{point}: Device or resource busy", 1},
      else: unmount(mounts, point)
  end

  defp answer(_system, _mounts, "mkfs.f2fs", ["-f", "-l", label, device]) do
    if File.exists?(device) do
      File.write!(device, f2fs_image(random_uuid(), label))
      {"Info: Format successful\n", 0}
    else
      {"\tError: Failed to open #{device}\n", 255}
    end
  end

  # The free bytes set for `path` or the folder it is in.
  defp free_bytes(system, path) do
    system
    |> Agent.get(& &1.free)
    |> Enum.find_value(@default_free_bytes, fn {folder, free_bytes} ->
      if path == folder or String.starts_with?(path, folder <> "/"), do: free_bytes
    end)
  end

  defp unmount(mounts, point) do
    lines = mounts |> File.read!() |> String.split("\n", trim: true)

    case Enum.split_with(lines, &match?([_device, ^point | _rest], String.split(&1))) do
      {[], _lines} ->
        {"umount: can't unmount #{point}: Invalid argument", 1}

      {_unmounted, kept} ->
        File.write!(mounts, Enum.map(kept, &(&1 <> "\n")))
        {"", 0}
    end
  end

  defp random_uuid do
    <<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>> =
      :crypto.strong_rand_bytes(16)

    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end
end
