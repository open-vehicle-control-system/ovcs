defmodule VisionCore.Stereo.Stage.PostFilter do
  @moduledoc """
  Median filter on the disparity, which removes isolated wrong-disparity
  pixels. `:kernel_size` (`5`).
  """
  @behaviour VisionCore.Stereo.Stage

  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.Stage
  def init(opts, _context), do: {:ok, Keyword.get(opts, :kernel_size, 5)}

  @impl VisionCore.Stereo.Stage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.Stage
  def run(%Pair{} = pair, kernel_size),
    do: {:ok, %{pair | disparity: Evision.medianBlur(pair.disparity, kernel_size)}, kernel_size}
end
