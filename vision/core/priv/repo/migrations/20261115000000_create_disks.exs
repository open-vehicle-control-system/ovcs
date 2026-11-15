defmodule VisionCore.Repo.Migrations.CreateDisks do
  use Ecto.Migration

  def change do
    create table(:disks) do
      add(:uuid, :string, null: false)
      add(:label, :string)
      add(:filesystem, :string)
      add(:position, :integer, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:last_seen_at, :utc_datetime)
    end

    create(unique_index(:disks, [:uuid]))
  end
end
