defmodule VmsApi.Repo do
  use Ecto.Repo,
    otp_app: :vms_api,
    adapter: Ecto.Adapters.SQLite3
end
