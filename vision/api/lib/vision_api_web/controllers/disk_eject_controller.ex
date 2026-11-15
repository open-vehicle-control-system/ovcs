defmodule VisionApiWeb.DiskEjectController do
  @moduledoc """
  Serves `disk-ejects`: creating one unmounts the USB disk its `disk`
  relationship names (`VisionCore.Disks.eject/2`), answering once it is
  unmounted. A recording on it closes its file and goes on on the next
  disk. The unit's storage, a disk not mounted and one that stays busy
  are refused: 409.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{DiskChangeJSON, DiskResource, JsonApi}
  alias VisionCore.Disks

  @type_name "disk-ejects"

  plug :put_view, json: DiskChangeJSON, jsonapi: DiskChangeJSON

  def create(conn, _params) do
    with {:ok, data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, disk} <- DiskResource.fetch_related(data),
         :ok <- eject(disk) do
      conn
      |> put_status(:created)
      |> render(:show, type: @type_name, id: JsonApi.action_id(), disk: disk, attributes: %{})
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end

  defp eject(%{uuid: nil, device: device}),
    do:
      {:error, 409, "#{device} has no filesystem the unit mounts",
       [source: DiskResource.disk_pointer()]}

  defp eject(disk) do
    with {:error, refusal} <- Disks.eject(DiskResource.server(), disk.uuid),
         do: DiskResource.refusal(refusal, source: DiskResource.disk_pointer())
  end
end
