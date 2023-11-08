defmodule OvcsInfotainmentBackend.Repo do
  use Ecto.Repo,
    otp_app: :ovcs_infotainment_backend,
    adapter: Ecto.Adapters.SQLite3
end
