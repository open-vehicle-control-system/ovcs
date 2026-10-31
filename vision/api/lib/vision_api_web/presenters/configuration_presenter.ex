defmodule VisionApiWeb.ConfigurationPresenter do
  @moduledoc """
  The active vision configuration as a `configurations` singleton: its
  `composer` attribute is `VisionCore.settings/0`, keyed by composer option
  names.
  """
  alias VisionApiWeb.JsonApi

  @spec present(map()) :: map()
  def present(settings), do: JsonApi.resource("configurations", "current", %{composer: settings})
end
