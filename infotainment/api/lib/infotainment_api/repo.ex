defmodule InfotainmentApi.Repo do
  use Ecto.Repo,
    otp_app: :infotainment_api,
    adapter: Ecto.Adapters.SQLite3
end
