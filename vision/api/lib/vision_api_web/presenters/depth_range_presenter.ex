defmodule VisionApiWeb.DepthRangePresenter do
  @moduledoc "The depth preview's colour range, from `VisionCore.Preview`'s options, as `%{metres: float}`."

  @spec present(%{depth_range_m: number()}) :: map()
  def present(%{depth_range_m: metres}), do: %{metres: metres}
end
