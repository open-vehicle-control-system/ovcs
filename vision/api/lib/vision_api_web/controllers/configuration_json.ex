defmodule VisionApiWeb.ConfigurationJSON do
  @moduledoc """
  The active vision configuration as a `configurations` singleton: its
  `composer` attribute is `VisionCore.settings/0`, keyed by composer option
  names.
  """
  alias VisionApiWeb.JsonApi

  @doc "The `current` configuration, whose `composer` attribute is `settings` (`VisionCore.settings/0`)."
  @spec show(%{settings: map()}) :: map()
  def show(%{settings: settings}),
    do: %{data: JsonApi.resource("configurations", "current", %{composer: settings})}
end
