defmodule VisionCore.Models.Disk do
  @moduledoc """
  A disk recordings go on, as `VisionCore.Disks` keeps it: its
  filesystem's `uuid`, `internal` for the unit's own storage, its `label`
  and `filesystem` when last seen, its `position` in the order the disks
  are filled in, whether it is `enabled`, and when it was `last_seen_at`,
  plugged in or pulled out.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @filesystems ["f2fs", "ext4"]

  @type t :: %__MODULE__{}

  schema "disks" do
    field(:uuid, :string)
    field(:label, :string)
    field(:filesystem, :string)
    field(:position, :integer)
    field(:enabled, :boolean, default: true)
    field(:last_seen_at, :utc_datetime)
  end

  @doc """
  The changeset of `disk` with `attributes`; `uuid` and `position` are
  required, and a `filesystem` is one the unit mounts.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = disk, attributes) do
    disk
    |> cast(attributes, [:uuid, :label, :filesystem, :position, :enabled, :last_seen_at])
    |> validate_required([:uuid, :position, :enabled])
    |> validate_inclusion(:filesystem, @filesystems)
    |> unique_constraint(:uuid)
  end
end
