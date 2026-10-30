defmodule VisionApiWeb.ConfigurationController do
  @moduledoc """
  The active vision configuration, read-only: a `configurations` singleton
  whose `composer` attribute is `VisionCore.settings/0`, keyed by composer
  option names.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi

  def show(conn, _params) do
    configuration =
      JsonApi.resource("configurations", "current", %{composer: VisionCore.settings()})

    JsonApi.send_document(conn, 200, %{data: configuration})
  end
end
