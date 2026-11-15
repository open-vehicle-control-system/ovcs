defmodule VisionCore.DisksTest do
  use ExUnit.Case, async: true

  alias VisionCore.{Disk, Disks, TestDisks}

  @moduletag :tmp_dir

  @stick "c8803634-2bd4-4a62-8a68-ad456f6a52ce"
  @other "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
  @gigabyte 1_000_000_000

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(5) && eventually(check, attempts - 1)
    end
  end

  defp state(disks, uuid) do
    case Disks.fetch(disks.server, uuid) do
      {:ok, %Disk{state: state}} -> state
      :error -> nil
    end
  end

  defp mounted!(disks, uuid), do: eventually(fn -> state(disks, uuid) == :mounted end)

  defp started(%{tmp_dir: dir}), do: %{disks: dir |> TestDisks.setup!() |> TestDisks.start!()}

  describe "the unit's storage" do
    setup :started

    test "is the disk internal, mounted, first on an empty database", %{disks: disks} do
      internal = disks.options[:internal]

      eventually(fn ->
        match?([%Disk{free_bytes: free} | _rest] when free != nil, Disks.list(disks.server))
      end)

      assert [
               %Disk{
                 uuid: "internal",
                 state: :mounted,
                 position: 0,
                 enabled: true,
                 recordings_path: ^internal,
                 free_bytes: 10_000_000_000
               }
             ] = Disks.list(disks.server)

      assert File.dir?(internal)
    end
  end

  describe "a USB disk plugged in" do
    setup :started

    test "is mounted under its UUID, noatime, its recordings folder made, last in the order",
         %{disks: disks} do
      TestDisks.plug(
        disks,
        "sda1",
        TestDisks.f2fs_image(@stick, "ovcs-recordings"),
        62_000_000_000
      )

      mounted!(disks, @stick)

      point = TestDisks.mount_point(disks, @stick)
      device = TestDisks.device_path(disks, "sda1")

      assert {:ok,
              %Disk{
                uuid: @stick,
                label: "ovcs-recordings",
                filesystem: :f2fs,
                device: "sda1",
                size_bytes: 62_000_000_000,
                position: 1,
                enabled: true,
                recordings_path: recordings
              }} = Disks.fetch(disks.server, @stick)

      assert recordings == Path.join(point, "recordings")
      assert File.dir?(recordings)

      assert TestDisks.commands(disks, "mount") == [
               ["-t", "f2fs", "-o", "noatime", device, point]
             ]

      assert Enum.map(Disks.list(disks.server), & &1.uuid) == ["internal", @stick]
    end

    test "with no partition table is mounted whole, as ext4", %{disks: disks} do
      TestDisks.plug(disks, "sdb", TestDisks.ext4_image(@other, "ext4-disk"))
      mounted!(disks, @other)

      assert {:ok, %Disk{filesystem: :ext4, device: "sdb", label: "ext4-disk"}} =
               Disks.fetch(disks.server, @other)

      assert [["-t", "ext4" | _rest]] = TestDisks.commands(disks, "mount")
    end

    test "of another filesystem is listed as unusable, and not mounted", %{disks: disks} do
      TestDisks.plug(disks, "sdc", TestDisks.blank_image())

      eventually(fn -> length(Disks.list(disks.server)) == 2 end)

      assert [%Disk{uuid: "internal"}, %Disk{uuid: nil, device: "sdc", state: :unusable} = sdc] =
               Disks.list(disks.server)

      assert sdc.problem == "no f2fs or ext4 filesystem"
      assert TestDisks.commands(disks, "mount") == []
    end

    test "is taken only on a USB bus, not as any SCSI disk", %{disks: disks} do
      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ata"), 64_000_000_000,
        bus: :ata
      )

      TestDisks.plug(disks, "sdb", TestDisks.ext4_image(@other, "usb"))
      mounted!(disks, @other)

      assert Disks.fetch(disks.server, @stick) == :error
      assert [["-t", "ext4" | _rest]] = TestDisks.commands(disks, "mount")
    end

    test "whose mount fails is unusable, saying why", %{tmp_dir: dir} do
      disks = dir |> Path.join("refused") |> TestDisks.setup!()

      disks =
        TestDisks.start!(disks,
          run: fn
            "mount", _arguments -> {"mount: permission denied", 1}
            command, arguments -> disks.options[:run].(command, arguments)
          end
        )

      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
      eventually(fn -> state(disks, @stick) == :unusable end)

      assert {:ok, %Disk{problem: problem}} = Disks.fetch(disks.server, @stick)
      assert problem =~ "permission denied"
    end
  end

  test "adopts a disk already mounted, wherever it is", %{tmp_dir: dir} do
    disks = TestDisks.setup!(dir)
    TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
    elsewhere = Path.join(dir, "elsewhere")
    File.mkdir_p!(elsewhere)

    File.write!(
      disks.options[:mounts_path],
      "#{TestDisks.device_path(disks, "sda1")} #{elsewhere} f2fs rw 0 0\n"
    )

    disks = TestDisks.start!(disks)
    mounted!(disks, @stick)

    assert {:ok, %Disk{recordings_path: recordings}} = Disks.fetch(disks.server, @stick)
    assert recordings == Path.join(elsewhere, "recordings")
    assert TestDisks.commands(disks, "mount") == []
  end

  describe "a disk pulled out" do
    setup :started

    test "is unplugged, unmounted lazily, and keeps its place until plugged again",
         %{disks: disks} do
      image = TestDisks.f2fs_image(@stick, "ovcs-recordings")
      TestDisks.plug(disks, "sda1", image)
      mounted!(disks, @stick)

      TestDisks.pull(disks, "sda1")
      eventually(fn -> state(disks, @stick) == :unplugged end)

      assert TestDisks.commands(disks, "umount") == [["-l", TestDisks.mount_point(disks, @stick)]]

      assert [%Disk{uuid: "internal"}, %Disk{uuid: @stick, position: 1, free_bytes: nil}] =
               Disks.list(disks.server)

      TestDisks.plug(disks, "sda1", image)
      mounted!(disks, @stick)
      assert length(TestDisks.commands(disks, "mount")) == 2
    end
  end

  describe "the order" do
    setup :started

    test "and the disks turned off survive a restart, unplugged", %{tmp_dir: dir, disks: disks} do
      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
      mounted!(disks, @stick)

      assert Disks.put_order(disks.server, [@stick, "internal"]) == :ok
      assert Disks.put_enabled(disks.server, "internal", false) == :ok
      TestDisks.pull(disks, "sda1")
      eventually(fn -> state(disks, @stick) == :unplugged end)
      TestDisks.stop!(disks)

      again = %{TestDisks.setup!(Path.join(dir, "again")) | repo: disks.repo}
      again = TestDisks.start!(again, repo: disks.repo)

      assert [
               %Disk{uuid: @stick, position: 0, enabled: true, state: :unplugged},
               %Disk{uuid: "internal", position: 1, enabled: false}
             ] = Disks.list(again.server)
    end

    test "names known disks only", %{disks: disks} do
      assert {:error, reason} = Disks.put_order(disks.server, [@other, "internal"])
      assert reason =~ @other
      assert {:error, _reason} = Disks.put_enabled(disks.server, @other, false)
    end

    test "puts the disks it does not name after those it names", %{disks: disks} do
      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
      TestDisks.plug(disks, "sdb", TestDisks.ext4_image(@other, "ext4-disk"))
      mounted!(disks, @stick)
      mounted!(disks, @other)

      assert Disks.put_order(disks.server, [@other]) == :ok
      assert Enum.map(Disks.list(disks.server), & &1.uuid) == [@other, "internal", @stick]
    end
  end

  describe "next/3" do
    setup :started

    setup %{disks: disks} do
      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
      mounted!(disks, @stick)
      :ok = Disks.put_order(disks.server, [@stick, "internal"])
      :ok
    end

    test "is the first disk mounted, turned on and above the floor", %{disks: disks} do
      assert {:ok, %Disk{uuid: @stick}} = Disks.next(disks.server, @gigabyte)

      # df counts in KiB.
      TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), 1_000_000 * 1024)

      eventually(fn ->
        match?({:ok, %Disk{uuid: "internal"}}, Disks.next(disks.server, 1_000_000 * 1024 + 1))
      end)

      assert {:ok, %Disk{uuid: @stick}} = Disks.next(disks.server, 1_000_000 * 1024)
    end

    test "skips a disk turned off and the disks named", %{disks: disks} do
      assert {:ok, %Disk{uuid: "internal"}} = Disks.next(disks.server, 0, [@stick])

      :ok = Disks.put_enabled(disks.server, @stick, false)
      assert {:ok, %Disk{uuid: "internal"}} = Disks.next(disks.server, 0)
    end

    test "says so when no disk is left", %{disks: disks} do
      assert {:error, reason} = Disks.next(disks.server, 0, [@stick, "internal"])
      assert reason =~ "no disk"
    end
  end

  describe "eject/2" do
    setup :started

    setup %{disks: disks} do
      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
      mounted!(disks, @stick)
      :ok
    end

    test "unmounts once the disk is no longer busy, and leaves it unmounted while plugged",
         %{disks: disks} do
      point = TestDisks.mount_point(disks, @stick)
      TestDisks.hold_busy(disks, true)
      eject = Task.async(fn -> Disks.eject(disks.server, @stick) end)

      eventually(fn -> length(TestDisks.commands(disks, "umount")) >= 2 end)
      assert state(disks, @stick) == :ejecting
      assert {:error, _no_disk} = Disks.next(disks.server, 0, ["internal"])

      TestDisks.hold_busy(disks, false)
      assert Task.await(eject) == :ok
      assert state(disks, @stick) == :ejected
      assert List.last(TestDisks.commands(disks, "umount")) == [point]

      mounts = length(TestDisks.commands(disks, "df"))
      eventually(fn -> length(TestDisks.commands(disks, "df")) > mounts + 2 end)
      assert state(disks, @stick) == :ejected
      assert length(TestDisks.commands(disks, "mount")) == 1

      TestDisks.pull(disks, "sda1")
      eventually(fn -> state(disks, @stick) == :unplugged end)
      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
      mounted!(disks, @stick)
    end

    test "answers an error and keeps the disk mounted when it stays busy", %{tmp_dir: dir} do
      disks =
        dir |> Path.join("busy") |> TestDisks.setup!() |> TestDisks.start!(eject_timeout_ms: 50)

      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
      mounted!(disks, @stick)
      TestDisks.hold_busy(disks, true)

      assert {:error, reason} = Disks.eject(disks.server, @stick)
      assert reason =~ "busy"
      assert state(disks, @stick) == :mounted
    end

    test "refuses the unit's storage and a disk not mounted", %{disks: disks} do
      assert {:error, _reason} = Disks.eject(disks.server, "internal")
      assert {:error, _reason} = Disks.eject(disks.server, @other)
    end
  end

  describe "format/3" do
    setup :started

    test "makes an unmounted USB disk f2fs with the label, then mounts it", %{disks: disks} do
      TestDisks.plug(disks, "sdc", TestDisks.blank_image())
      eventually(fn -> length(Disks.list(disks.server)) == 2 end)

      assert Disks.format(disks.server, "sdc", "new-recordings") == :ok

      assert TestDisks.commands(disks, "mkfs.f2fs") == [
               ["-f", "-l", "new-recordings", TestDisks.device_path(disks, "sdc")]
             ]

      eventually(fn ->
        match?(
          [_internal, %Disk{label: "new-recordings", device: "sdc", state: :mounted}],
          Disks.list(disks.server)
        )
      end)
    end

    test "refuses a mounted disk, a device that is no USB disk, and a label f2fs cannot hold",
         %{disks: disks} do
      TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
      mounted!(disks, @stick)

      assert {:error, reason} = Disks.format(disks.server, "sda1", "label")
      assert reason =~ "mounted"
      assert {:error, _reason} = Disks.format(disks.server, "mmcblk0p72", "label")

      :ok = Disks.eject(disks.server, @stick)
      assert {:error, _reason} = Disks.format(disks.server, "sda1", String.duplicate("a", 513))
      assert TestDisks.commands(disks, "mkfs.f2fs") == []
    end

    test "says why mkfs.f2fs failed", %{disks: disks} do
      TestDisks.plug(disks, "sdc", TestDisks.blank_image())
      eventually(fn -> length(Disks.list(disks.server)) == 2 end)
      File.rm!(TestDisks.device_path(disks, "sdc"))

      assert {:error, reason} = Disks.format(disks.server, "sdc", "label")
      assert reason =~ "Failed to open"
    end
  end

  test "without a database mounts and chooses disks, and refuses to save the order",
       %{tmp_dir: dir} do
    dead_repo = spawn(fn -> :ok end)
    disks = dir |> TestDisks.setup!() |> TestDisks.start!(repo: dead_repo)

    TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
    mounted!(disks, @stick)

    assert {:ok, %Disk{uuid: "internal"}} = Disks.next(disks.server, 0)
    assert {:error, reason} = Disks.put_order(disks.server, [@stick, "internal"])
    assert reason =~ "unavailable"
    assert Enum.map(Disks.list(disks.server), & &1.uuid) == ["internal", @stick]
  end

  test "watches no USB disk unless asked, as on a host", %{tmp_dir: dir} do
    disks = TestDisks.setup!(dir)
    TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
    disks = %{disks | server: start_supervised!({Disks, disks.options})}

    eventually(fn -> length(TestDisks.commands(disks, "df")) > 3 end)
    assert Enum.map(Disks.list(disks.server), & &1.uuid) == ["internal"]
    assert TestDisks.commands(disks, "mount") == []
  end
end
