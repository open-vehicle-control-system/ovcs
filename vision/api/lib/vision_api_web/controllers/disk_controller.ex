defmodule VisionApiWeb.DiskController do
  @moduledoc """
  The disks recordings go on (`VisionCore.Disks`), as `disks` resources
  (`VisionApiWeb.DiskResource`): listed in the order they are filled,
  then those without a filesystem the unit mounts, and changed. A change
  turns a disk on or off with `enabled` and moves it in the order with
  `position`, 0 first, the others keeping their order. A disk without a
  filesystem has no place in the order: 409. A unit without a bag
  exporter watches no disk: an empty list.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{DiskResource, JsonApi}
  alias VisionCore.Disks

  @type_name "disks"
  @attributes_pointer "/data/attributes"
  @position_pointer "/data/attributes/position"
  @enabled_pointer "/data/attributes/enabled"

  def index(conn, _params), do: render(conn, :index, disks: Disks.list(DiskResource.server()))

  def update(conn, %{"id" => id}) do
    data = JsonApi.document(conn)["data"]

    with :ok <- JsonApi.check_identity(data, @type_name, id),
         {:ok, changes} <- fetch_changes(data),
         {:ok, disk} <- DiskResource.fetch(id),
         :ok <- check_ordered(disk),
         :ok <- check_position(changes),
         :ok <- put_enabled(disk, changes),
         :ok <- put_position(disk, changes),
         {:ok, changed} <- DiskResource.fetch(id) do
      render(conn, :show, disk: changed)
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end

  defp fetch_changes(%{"attributes" => %{} = attributes}) do
    with {:ok, position} <-
           optional(attributes, "position", &(is_integer(&1) and &1 >= 0), "a count from 0"),
         {:ok, enabled} <- optional(attributes, "enabled", &is_boolean/1, "a boolean") do
      case Map.reject(%{position: position, enabled: enabled}, fn {_change, value} ->
             is_nil(value)
           end) do
        none when map_size(none) == 0 -> no_change()
        changes -> {:ok, changes}
      end
    end
  end

  defp fetch_changes(_data), do: no_change()

  defp no_change,
    do:
      {:error, 400, "data.attributes takes a position, a count from 0, or enabled, a boolean",
       [source: @attributes_pointer]}

  defp optional(attributes, key, valid?, what) do
    case Map.fetch(attributes, key) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        if valid?.(value),
          do: {:ok, value},
          else:
            {:error, 400, "data.attributes.#{key} is #{what}",
             [source: "#{@attributes_pointer}/#{key}"]}
    end
  end

  defp check_ordered(%{uuid: nil, device: device}),
    do:
      {:error, 409, "#{device} has no filesystem the unit mounts: format it first",
       [title: "No filesystem"]}

  defp check_ordered(_disk), do: :ok

  # Before any change, so a refused change changes nothing.
  defp check_position(%{position: position}) do
    last = Enum.count(Disks.list(DiskResource.server()), &(&1.position != nil)) - 1

    if position <= last,
      do: :ok,
      else: {:error, 422, "a position is from 0 to #{last}", [source: @position_pointer]}
  end

  defp check_position(_changes), do: :ok

  defp put_enabled(disk, %{enabled: enabled}) do
    with {:error, refusal} <- Disks.put_enabled(DiskResource.server(), disk.uuid, enabled),
         do: DiskResource.refusal(refusal, source: @enabled_pointer)
  end

  defp put_enabled(_disk, _changes), do: :ok

  defp put_position(disk, %{position: position}) do
    with {:error, refusal} <- Disks.put_position(DiskResource.server(), disk.uuid, position),
         do: DiskResource.refusal(refusal, source: @position_pointer)
  end

  defp put_position(_disk, _changes), do: :ok
end
