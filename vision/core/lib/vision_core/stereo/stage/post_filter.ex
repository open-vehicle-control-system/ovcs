defmodule VisionCore.Stereo.Stage.PostFilter do
  @moduledoc """
  Median filter on the disparity, which removes isolated
  wrong-disparity pixels. `:kernel_size` (`5`), 3 or 5.
  """
  @behaviour VisionCore.Stereo.NxStage

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Removes isolated wrong disparities with a median filter."

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context) do
    case Keyword.get(opts, :kernel_size, 5) do
      size when size in [3, 5] -> {:ok, size}
      size -> {:error, "kernel_size must be 3 or 5, got #{inspect(size)}"}
    end
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def params(_state, _context), do: %{}

  @impl VisionCore.Stereo.NxStage
  def option_specs do
    [
      kernel_size: %{
        type: :integer,
        values: [3, 5],
        applies: :build,
        description: "Width of the median filter's square window, in pixels"
      }
    ]
  end

  @impl VisionCore.Stereo.NxStage
  def options(kernel_size), do: %{kernel_size: kernel_size}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, _params, kernel_size),
    do: Map.put(tensors, :disparity, NxStereo.Image.median(tensors.disparity, kernel_size))
end
