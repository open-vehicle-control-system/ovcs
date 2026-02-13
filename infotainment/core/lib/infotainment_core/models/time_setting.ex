defmodule InfotainmentCore.Models.TimeSetting do
  @moduledoc """
    Store the time display settings (timezone, time format, date format).
    Uses a single-row pattern — only one record exists in this table.
  """
  use Ecto.Schema

  schema "time_settings" do
    field :timezone, :string, default: "UTC"
    field :time_format, :string, default: "24h"
    field :date_format, :string, default: "DD/MM/YYYY"
    timestamps()
  end
end
