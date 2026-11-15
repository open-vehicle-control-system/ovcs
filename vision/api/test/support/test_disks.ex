defmodule VisionApiWeb.TestDisks do
  @moduledoc """
  The options of a `VisionCore.Disks` on a fake system under a test's
  folder, for the bag exporter a test unit runs: `sys/block`, `dev`, a
  `mounts` file, the unit's storage `recordings`, mount points under
  `disks`, a database of its own in memory, and commands that change
  those files as `mount`, `umount` and `mkfs.f2fs` would. `df` answers
  10 GB free; `umount` answers busy while `hold_busy/2` says so, and
  `mkfs.f2fs` fails once `fail_mkfs/1` is called.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 2]

  alias VisionCore.{Disks, Repo}

  @free_kib 10_000_000
  @sector_bytes 512
  @usb_device "platform/soc/xhci-hcd.0/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0"

  @doc "The disks' options on a fake system in `dir`, watching USB disks."
  @spec options(Path.t()) :: keyword()
  def options(dir) do
    mounts = Path.join(dir, "mounts")
    File.mkdir_p!(Path.join(dir, "sys/block"))
    File.mkdir_p!(Path.join(dir, "dev"))
    File.write!(mounts, "")

    [
      internal: Path.join(dir, "recordings"),
      mount_root: Path.join(dir, "disks"),
      usb: true,
      block_devices_path: Path.join(dir, "sys/block"),
      devices_path: Path.join(dir, "dev"),
      mounts_path: mounts,
      poll_interval_ms: 10,
      repo: start_repo!(),
      run: fn command, arguments -> run(dir, mounts, command, arguments) end
    ]
  end

  defp start_repo! do
    repo =
      start_supervised!({Repo, name: nil, database: ":memory:", pool_size: 1, log: false},
        id: make_ref()
      )

    Ecto.Migrator.run(Repo, migrations(), :up, all: true, dynamic_repo: repo, log: false)
    repo
  end

  # The migrations by version, each compiled once: compiling a file again redefines its module.
  defp migrations do
    for path <- Path.wildcard(Application.app_dir(:vision_core, "priv/repo/migrations/*.exs")) do
      [version, name] = path |> Path.basename(".exs") |> String.split("_", parts: 2)
      module = Module.concat(Repo.Migrations, Macro.camelize(name))
      unless Code.ensure_loaded?(module), do: Code.compile_file(path)
      {String.to_integer(version), module}
    end
  end

  @doc """
  Restarts the vision core on a unit running the bag exporter, recording
  on disks of a fake system in `dir`, its internal one mounted, with the
  disks' options `overrides`; answers the disks' options.
  """
  @spec start_unit(Path.t(), keyword()) :: keyword()
  def start_unit(dir, overrides \\ []) do
    options = Keyword.merge(options(dir), overrides)

    exporter =
      {VisionCore.Ros2.BagExporter,
       disks: Keyword.delete(options, :internal),
       root: options[:internal],
       free_floor_bytes: 0,
       parameters: fn -> [] end,
       clock_synchronized?: fn -> true end}

    :ok = VisionApiWeb.TestUnit.start(%VisionCore.Config{exporters: [exporter]})
    eventually(fn -> match?({:ok, %{state: :mounted}}, Disks.fetch(Disks, "internal")) end)
    eventually(&bag_exporter_answers?/0)
    options
  end

  defp bag_exporter_answers? do
    case VisionCore.Exporters.fetch_runner("ros2_bag") do
      {:ok, runner} -> VisionCore.Ros2.BagExporter.recording(runner) == {:ok, nil}
      {:error, _reason} -> false
    end
  end

  @doc "Waits for `check` to hold, a second at most."
  @spec eventually((-> boolean()), non_neg_integer()) :: :ok
  def eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> ExUnit.Assertions.flunk("the condition never held")
      true -> wait_and_retry(check, attempts)
    end
  end

  defp wait_and_retry(check, attempts) do
    Process.sleep(5)
    eventually(check, attempts - 1)
  end

  @doc """
  Plugs `device`, a partition such as `sda1`, holding `image`, in the
  system of `options`: its disk's `/sys/block` entry links to a device on
  a USB bus.
  """
  @spec plug(keyword(), String.t(), binary()) :: :ok
  def plug(options, device, image) do
    File.write!(Path.join(options[:devices_path], device), image)
    [_device, parent] = Regex.run(~r/^(sd[a-z]+)\d+$/, device)
    block = Path.join(disk_directory(options, parent), device)
    File.mkdir_p!(block)
    File.write!(Path.join(block, "size"), "#{div(64_000_000_000, @sector_bytes)}\n")
  end

  # The disk's sysfs folder, with a diskseq of its own, and its `/sys/block` link, made the first time.
  defp disk_directory(options, parent) do
    link = Path.join(options[:block_devices_path], parent)
    target = Path.join(["..", "devices", @usb_device, "block", parent])
    disk = Path.expand(target, options[:block_devices_path])

    unless File.dir?(disk) do
      File.mkdir_p!(disk)
      diskseq = System.unique_integer([:positive, :monotonic])
      File.write!(Path.join(disk, "diskseq"), "#{diskseq}\n")
      File.ln_s!(target, link)
    end

    disk
  end

  @doc "Makes `umount` of the system in `dir` answer busy, or not."
  @spec hold_busy(Path.t(), boolean()) :: :ok
  def hold_busy(dir, true), do: File.write!(Path.join(dir, "busy"), "")
  def hold_busy(dir, false), do: File.rm!(Path.join(dir, "busy"))

  @doc "Makes `mkfs.f2fs` of the system in `dir` fail, as on a device pulled out while it formats."
  @spec fail_mkfs(Path.t()) :: :ok
  def fail_mkfs(dir), do: File.write!(Path.join(dir, "mkfs_fails"), "")

  @doc "An f2fs superblock labelled `label`, as the first 4 KiB of its partition."
  @spec f2fs_image(String.t(), String.t()) :: binary()
  def f2fs_image(uuid, label) do
    label = :unicode.characters_to_binary(label, :utf8, {:utf16, :little})
    uuid = uuid |> String.replace("-", "") |> Base.decode16!(case: :lower)

    image(
      <<0::size(1024 * 8), 0xF2F52010::little-32, 0::size(104 * 8), uuid::binary, label::binary>>
    )
  end

  @doc "4 KiB of no filesystem."
  @spec blank_image() :: binary()
  def blank_image, do: image(<<>>)

  defp image(head), do: head <> :binary.copy(<<0>>, 4096 - byte_size(head))

  defp run(_dir, _mounts, "df", ["-P", "-k", path]) do
    {"Filesystem 1024-blocks Used Available Capacity Mounted on\n" <>
       "/dev/fake #{@free_kib + 1000} 1000 #{@free_kib} 1% #{path}\n", 0}
  end

  defp run(_dir, mounts, "mount", ["-t", filesystem, "-o", options, device, point]) do
    File.write!(mounts, "#{device} #{point} #{filesystem} rw,#{options} 0 0\n", [:append])
    {"", 0}
  end

  defp run(dir, mounts, "umount", [point]) do
    if File.exists?(Path.join(dir, "busy")),
      do: {"umount: can't unmount #{point}: Device or resource busy", 1},
      else: unmount(mounts, point)
  end

  defp run(_dir, mounts, "umount", ["-l", point]), do: unmount(mounts, point)

  defp run(dir, _mounts, "mkfs.f2fs", ["-f", "-l", label, device]) do
    if File.exists?(Path.join(dir, "mkfs_fails")) do
      {"\tError: Failed to open #{device}\n", 255}
    else
      File.write!(device, f2fs_image("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", label))
      {"Info: Format successful\n", 0}
    end
  end

  defp unmount(mounts, point) do
    lines = mounts |> File.read!() |> String.split("\n", trim: true)
    kept = Enum.reject(lines, &match?([_device, ^point | _rest], String.split(&1)))
    File.write!(mounts, Enum.map(kept, &(&1 <> "\n")))
    {"", 0}
  end
end
