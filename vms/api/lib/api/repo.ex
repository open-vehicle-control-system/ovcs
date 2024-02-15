defmodule VmsApi.Repo do
  use Ecto.Repo,
    otp_app: :api,
    adapter: Ecto.Adapters.SQLite3
end
