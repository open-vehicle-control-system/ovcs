defmodule InfotainmentCore.Repo do
  @moduledoc """
    Infotainment SQLite repository
  """
  use Ecto.Repo,
    otp_app: :infotainment_core,
    adapter: Ecto.Adapters.SQLite3
end
