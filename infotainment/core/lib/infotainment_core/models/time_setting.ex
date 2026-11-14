defmodule InfotainmentCore.Models.TimeSetting do
  @moduledoc """
    Store the time display settings (timezone, time format, date format).
    Uses a single-row pattern — only one record exists in this table.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "time_settings" do
    field(:timezone, :string, default: "UTC")
    field(:time_format, :string, default: "24h")
    field(:date_format, :string, default: "DD/MM/YYYY")
    timestamps()
  end

  @doc """
  The changeset of `settings` with `attributes`: `timezone`, `time_format`
  and `date_format`, each stored as given, an empty one included.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = settings, attributes),
    do: cast(settings, attributes, [:timezone, :time_format, :date_format], empty_values: [])
end
