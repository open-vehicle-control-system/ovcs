defmodule VmsCore.Repo do
  @moduledoc """
    VMS SQLite repository
  """
  use Ecto.Repo,
    otp_app: :vms_core,
    adapter: Ecto.Adapters.SQLite3
end
