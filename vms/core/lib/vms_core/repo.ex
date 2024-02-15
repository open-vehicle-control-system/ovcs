defmodule VmsCore.Repo do
  use Ecto.Repo,
    otp_app: :vms_core,
    adapter: Ecto.Adapters.SQLite3
end
