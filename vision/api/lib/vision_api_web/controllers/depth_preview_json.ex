defmodule VisionApiWeb.DepthPreviewJSON do
  @moduledoc """
  The depth video as a `depth-previews` singleton: `colourRangeM`, the
  distance coloured blue, in metres, `0` for infinitely far.
  """
  alias VisionApiWeb.JsonApi

  @doc "The `current` depth preview, from `options` (`VisionCore.Preview.options/0`)."
  @spec show(%{options: %{depth_range_m: float()}}) :: map()
  def show(%{options: %{depth_range_m: metres}}),
    do: %{data: JsonApi.resource("depth-previews", "current", %{colourRangeM: metres})}
end
