defmodule VisionApiWeb.DiskChangeJSON do
  @moduledoc """
  A change made to one disk, `disk-ejects` or `disk-formats`, as a
  JSON:API resource related to the `disk` it changed.
  """
  alias VisionApiWeb.{DiskResource, JsonApi}

  @doc "The change of `type` and `id`, with its `attributes`, made to `disk`."
  @spec show(%{type: String.t(), id: String.t(), disk: VisionCore.Disk.t(), attributes: map()}) ::
          map()
  def show(%{type: type, id: id, disk: disk, attributes: attributes}),
    do: %{
      data:
        JsonApi.resource(type, id, attributes, %{
          disk: JsonApi.to_one("disks", DiskResource.id(disk))
        })
    }
end
