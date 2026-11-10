defmodule VisionCore.Stereo.Stage.MedianFilter do
  @moduledoc """
  Median filter on the disparity, over each pixel's square window.

  It is not a default stage: `NxStereo.sgm/3`, and so
  `VisionCore.Stereo.Stage.Disparity`, ends with a 3×3 median already.
  Add it after `Disparity` in a vehicle's stage list for a wider window.

  The median does not skip unmatched pixels (-1): they are values like
  the others, and the lowest in the window. A pixel is unmatched in the
  result when more than half of its window is, itself included, and an
  unmatched pixel whose window is mostly matched takes a matched value:
  holes close, and thin or pointed matched areas wear away. Next to a
  hole the result can be a lower disparity, which reads farther, than
  the median of the matched pixels alone.

  ## Options

    * `:kernel_size` (`5`) — the window's width, 3 or 5; fixed in the
      build.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check

  @option_specs [
    kernel_size: %{
      type: :integer,
      values: [3, 5],
      applies: :build,
      description: "Width of the median filter's square window, in pixels"
    }
  ]

  @defaults %{kernel_size: 5}

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Removes isolated wrong disparities with a median filter."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Replaces each disparity with the median of its neighbourhood. A lone wrong value " <>
        "among good ones disappears, while the edges of objects stay sharp, which an average " <>
        "would blur. kernel_size, fixed in the build, is the neighbourhood's width: wider " <>
        "removes larger errors and rounds off fine detail. The matching already ends with a " <>
        "3 × 3 median, so this stage is for a wider one. An unmatched pixel counts as the " <>
        "lowest value: a hole that is mostly surrounded by matches fills, and a match that is " <>
        "mostly surrounded by holes is dropped."

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    with {:ok, settings} <- Check.init_settings(@option_specs, @defaults, opts),
         do: NxStereo.Stage.MedianFilter.init(Map.to_list(settings), context)
  end

  @impl VisionCore.Stereo.NxStage
  def stereo_stage, do: NxStereo.Stage.MedianFilter

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  defdelegate native_kind, to: NxStereo.Stage.MedianFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate native_settings(state), to: NxStereo.Stage.MedianFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: NxStereo.Stage.MedianFilter

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{kernel_size: state.kernel_size}
end
