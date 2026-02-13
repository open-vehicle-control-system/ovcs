defmodule InfotainmentCore.Repo.Migrations.CreateTimeSettings do
  use Ecto.Migration

  def change do
    create table(:time_settings) do
      add :timezone, :string, default: "UTC"
      add :time_format, :string, default: "24h"
      add :date_format, :string, default: "DD/MM/YYYY"
      timestamps()
    end
  end
end
