defmodule VisionCore.Models.DiskTest do
  use ExUnit.Case, async: true

  alias VisionCore.Models.Disk

  test "takes a disk's UUID, label, filesystem, place in the order and whether it is on" do
    seen_at = ~U[2026-11-15 10:00:00Z]

    changeset =
      Disk.changeset(%Disk{}, %{
        uuid: "c8803634-2bd4-4a62-8a68-ad456f6a52ce",
        label: "ovcs-recordings",
        filesystem: "f2fs",
        position: 1,
        enabled: false,
        last_seen_at: seen_at
      })

    assert changeset.valid?

    assert changeset.changes == %{
             uuid: "c8803634-2bd4-4a62-8a68-ad456f6a52ce",
             label: "ovcs-recordings",
             filesystem: "f2fs",
             position: 1,
             enabled: false,
             last_seen_at: seen_at
           }
  end

  test "refuses a disk without its UUID or place, or with a filesystem it cannot mount" do
    changeset = Disk.changeset(%Disk{}, %{uuid: nil, position: nil, filesystem: "vfat"})

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.errors[:uuid]
    assert {_message, [validation: :required]} = changeset.errors[:position]

    assert {_message, [validation: :inclusion, enum: _filesystems]} =
             changeset.errors[:filesystem]
  end
end
