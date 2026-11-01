defmodule VisionApiWeb.DepthRangePresenter do
  @moduledoc "The depth preview's colour range, from `VisionCore.Preview`'s options, as `%{metres: float}`."

  @doc "The depth video's colour range in `options` (`VisionCore.Preview.options/0`)."
  @spec present(%{depth_range_m: number()}) :: map()
  def present(%{depth_range_m: metres}), do: %{metres: metres}
end
