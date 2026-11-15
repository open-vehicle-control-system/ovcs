defmodule VisionApiWeb.DiskJSON do
  @moduledoc """
  Disks (`VisionCore.Disk`) as `disks` JSON:API resources, identified as
  `VisionApiWeb.DiskResource.id/1` says: whether it is the unit's own
  storage, its `label`, `filesystem`, `device`, `sizeBytes`,
  `freeBytes`, `position` in the order, `enabled`, `state` (`mounted`,
  `ejecting`, `ejected`, `unplugged`, `unusable` or `formatting`), the `problem` that
  makes it unusable and when it was `lastSeenAt`. A value the unit does
  not know, such as an unplugged disk's free bytes, is `null`.
  """
  alias VisionApiWeb.{DiskResource, JsonApi}
  alias VisionCore.Disk

  @doc "The disks, in the order `VisionCore.Disks.list/1` gives."
  @spec index(%{disks: [Disk.t()]}) :: map()
  def index(%{disks: disks}), do: %{data: Enum.map(disks, &data/1)}

  @doc "One disk."
  @spec show(%{disk: Disk.t()}) :: map()
  def show(%{disk: disk}), do: %{data: data(disk)}

  defp data(%Disk{} = disk) do
    JsonApi.resource("disks", DiskResource.id(disk), %{
      internal: disk.uuid == "internal",
      label: disk.label,
      filesystem: disk.filesystem && Atom.to_string(disk.filesystem),
      device: disk.device,
      sizeBytes: disk.size_bytes,
      freeBytes: disk.free_bytes,
      position: disk.position,
      enabled: disk.enabled,
      state: Atom.to_string(disk.state),
      problem: disk.problem,
      lastSeenAt: disk.last_seen_at
    })
  end
end
