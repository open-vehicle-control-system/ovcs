defmodule VisionCore.Repo do
  @moduledoc """
  The vision unit's SQLite repository, holding the saved parameter values
  (`VisionCore.Parameters.SavedValue`).
  """
  use Ecto.Repo,
    otp_app: :vision_core,
    adapter: Ecto.Adapters.SQLite3
end
