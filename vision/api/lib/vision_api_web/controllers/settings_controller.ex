defmodule VisionApiWeb.SettingsController do
  @moduledoc "The active vision configuration, read-only."
  use VisionApiWeb, :controller

  def show(conn, _params), do: json(conn, VisionCore.settings())
end
