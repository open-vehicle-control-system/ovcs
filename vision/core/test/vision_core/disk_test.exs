defmodule VisionCore.DiskTest do
  use ExUnit.Case, async: true

  alias VisionCore.Disk

  # The first 4 KiB of a SanDisk stick formatted by the unit's `mkfs.f2fs -l ovcs-recordings`,
  # and of an image made by `mkfs.ext4 -U 0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0 -L ovcs-ext4-test`;
  # the UUIDs and labels are those `blkid -p` reads from them.
  @f2fs "test/fixtures/disks/f2fs_superblock.bin"
  @ext4 "test/fixtures/disks/ext4_superblock.bin"

  describe "identify/1" do
    test "reads an f2fs superblock's UUID and label" do
      assert Disk.identify(File.read!(@f2fs)) ==
               {:ok,
                %{
                  filesystem: :f2fs,
                  uuid: "c8803634-2bd4-4a62-8a68-ad456f6a52ce",
                  label: "ovcs-recordings"
                }}
    end

    test "reads an ext4 superblock's UUID and label" do
      assert Disk.identify(File.read!(@ext4)) ==
               {:ok,
                %{
                  filesystem: :ext4,
                  uuid: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0",
                  label: "ovcs-ext4-test"
                }}
    end

    test "refuses another filesystem, a superblock without a UUID, and a short read" do
      assert Disk.identify(:binary.copy(<<0>>, 4096)) == {:error, "no f2fs or ext4 filesystem"}

      <<head::binary-size(1132), _uuid::binary-size(16), rest::binary>> = File.read!(@f2fs)

      assert Disk.identify(head <> :binary.copy(<<0>>, 16) <> rest) ==
               {:error, "the filesystem has no UUID"}

      assert Disk.identify(binary_part(File.read!(@ext4), 0, 1100)) ==
               {:error, "no f2fs or ext4 filesystem"}
    end
  end

  describe "read_identity/1" do
    test "reads a device's superblock" do
      assert {:ok, %{uuid: "c8803634-2bd4-4a62-8a68-ad456f6a52ce"}} = Disk.read_identity(@f2fs)
    end

    test "says why a device cannot be read" do
      assert {:error, reason} = Disk.read_identity("test/fixtures/disks/missing")
      assert reason =~ "test/fixtures/disks/missing"
    end
  end

  describe "writable?/2" do
    test "a mounted disk with the floor free" do
      disk = %Disk{uuid: "internal", state: :mounted, free_bytes: 1_000}

      assert Disk.writable?(disk, 1_000)
      refute Disk.writable?(disk, 1_001)
      refute Disk.writable?(%{disk | state: :ejecting}, 0)
      refute Disk.writable?(%{disk | state: :unplugged, free_bytes: nil}, 0)
    end
  end
end
