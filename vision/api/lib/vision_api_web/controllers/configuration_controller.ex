defmodule VisionApiWeb.ConfigurationController do
  @moduledoc """
  The active vision configuration, read-only: a `configurations` singleton
  whose `composer` attribute is `VisionCore.settings/0`, keyed by composer
  option names.
  """
  use VisionApiWeb, :controller

  def show(conn, _params), do: render(conn, :show, settings: VisionCore.settings())
end
