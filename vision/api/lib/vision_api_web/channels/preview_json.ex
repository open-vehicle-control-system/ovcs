defmodule VisionApiWeb.PreviewJSON do
  @moduledoc "The preview channel's JSON payload: the depth video's colour range, from `VisionCore.Preview`'s options."

  @doc "The depth video's colour range in `options` (`VisionCore.Preview.options/0`), as `%{metres: float}`."
  @spec depth_range(%{depth_range_m: number()}) :: map()
  def depth_range(%{depth_range_m: metres}), do: %{metres: metres}
end
