defmodule VmsCore.Repo.Migrations.CreateControlsCalibrations do
  use Ecto.Migration

  def change do
    create table(:ControlsCalibration) do
      add :key, :string
      add :value, :integer
      timestamps()
    end
  end
end
