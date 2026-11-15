defmodule VisionApiWeb.DiskResource do
  @moduledoc """
  How the API names the disks recordings go on (`VisionCore.Disks`, the
  one registered under that name), for the controllers of `disks`,
  `disk-ejects` and `disk-formats`: a disk's id, its filesystem's UUID,
  `internal` for the unit's storage, or for a disk without a filesystem
  the unit mounts, its device, such as `sdb1`; the disk an id or a
  document's `disk` relationship names; and the status of each refusal
  of `VisionCore.Disks`.
  """
  alias VisionApiWeb.JsonApi
  alias VisionCore.{Disk, Disks}

  @disk_pointer "/data/relationships/disk"
  @statuses %{not_found: 404, conflict: 409, invalid: 422, failed: 500, unavailable: 503}

  @doc "The `VisionCore.Disks` the API reads and changes."
  @spec server() :: GenServer.server()
  def server, do: Disks

  @doc "The id of `disk`."
  @spec id(Disk.t()) :: String.t()
  def id(%Disk{uuid: nil, device: device}), do: device
  def id(%Disk{uuid: uuid}), do: uuid

  @doc "The disk of `id`, or the 404 `VisionApiWeb.JsonApi.refuse/2` sends, its `source` `options`."
  @spec fetch(String.t(), keyword()) :: {:ok, Disk.t()} | JsonApi.refusal()
  def fetch(id, options \\ []) do
    case Enum.find(Disks.list(server()), &(id(&1) == id)) do
      nil -> {:error, 404, "no disk #{id}", options}
      disk -> {:ok, disk}
    end
  end

  @doc """
  The disk the `disk` relationship of `data`, a write's resource object,
  names; a 400 without one, a 404 for a disk the unit does not know.
  """
  @spec fetch_related(map()) :: {:ok, Disk.t()} | JsonApi.refusal()
  def fetch_related(%{
        "relationships" => %{"disk" => %{"data" => %{"type" => "disks", "id" => id}}}
      })
      when is_binary(id),
      do: fetch(id, source: @disk_pointer)

  def fetch_related(_data),
    do: {:error, 400, "disk must name one of the disks", [source: @disk_pointer]}

  @doc "The JSON:API refusal of `refusal`, a `VisionCore.Disks` one, its `source` `options`."
  @spec refusal(Disks.refusal(), keyword()) :: JsonApi.refusal()
  def refusal({kind, reason}, options), do: {:error, Map.fetch!(@statuses, kind), reason, options}

  @doc "The pointer of a write's `disk` relationship."
  @spec disk_pointer() :: String.t()
  def disk_pointer, do: @disk_pointer
end
