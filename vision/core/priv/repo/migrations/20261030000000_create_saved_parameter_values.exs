defmodule VisionCore.Repo.Migrations.CreateSavedParameterValues do
  use Ecto.Migration

  def change do
    create table(:saved_parameter_values) do
      add :parameter_id, :string, null: false
      add :value, :string, null: false
      timestamps()
    end

    create unique_index(:saved_parameter_values, [:parameter_id])
  end
end
