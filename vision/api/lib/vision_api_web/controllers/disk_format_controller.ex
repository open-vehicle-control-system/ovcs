defmodule VisionApiWeb.DiskFormatController do
  @moduledoc """
  Serves `disk-formats`: creating one makes the USB disk its `disk`
  relationship names f2fs, labelled with its `label` attribute
  (`VisionCore.Disks.format/3`), answering once it is formatted; the
  unit mounts it at its next look at the disks, as a new disk of another
  id. The unit's storage, a mounted disk and one not plugged in are
  refused: 409; a label f2fs cannot hold: 422.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{DiskChangeJSON, DiskResource, JsonApi}
  alias VisionCore.Disks

  @type_name "disk-formats"
  @label_pointer "/data/attributes/label"

  plug :put_view, json: DiskChangeJSON, jsonapi: DiskChangeJSON

  def create(conn, _params) do
    with {:ok, data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, label} <- fetch_label(data),
         {:ok, disk} <- DiskResource.fetch_related(data),
         :ok <- format(disk, label) do
      conn
      |> put_status(:created)
      |> render(:show,
        type: @type_name,
        id: JsonApi.action_id(),
        disk: disk,
        attributes: %{label: label}
      )
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end

  defp fetch_label(%{"attributes" => %{"label" => label}}) when is_binary(label), do: {:ok, label}

  defp fetch_label(_data),
    do:
      {:error, 400, "data.attributes.label is the disk's new label, text",
       [source: @label_pointer]}

  defp format(%{uuid: "internal"}, _label),
    do: conflict("the unit's storage is not formatted")

  defp format(%{device: nil} = disk, _label),
    do: conflict("#{DiskResource.id(disk)} is not plugged in")

  defp format(disk, label) do
    case Disks.format(DiskResource.server(), disk.device, label) do
      :ok ->
        :ok

      {:error, {:invalid, _reason} = refusal} ->
        DiskResource.refusal(refusal, source: @label_pointer)

      {:error, refusal} ->
        DiskResource.refusal(refusal, source: DiskResource.disk_pointer())
    end
  end

  defp conflict(reason), do: {:error, 409, reason, [source: DiskResource.disk_pointer()]}
end
