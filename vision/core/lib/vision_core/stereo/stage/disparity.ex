defmodule VisionCore.Stereo.Stage.Disparity do
  @moduledoc """
  Matches the rectified pair with `NxStereo.sgm/3`: libSGM's
  semi-global matching, as compute shaders on a Vulkan GPU through
  `nx_iree`, or compiled for the CPU. The disparity stays in `f32` pixels
  (`disparity_scale` 1.0): positive where matched, -1 where unmatched. A
  match at disparity 0, which `NxStereo.sgm/3` finds on points too far
  to measure and in the leftmost columns, has no depth: it is unmatched.

  `NxStereo.sgm/3` ends with a 3×3 median filter of the checked
  disparity, and so does the native matcher, so the default stages have
  no median filter after this one. To that median, unmatched pixels
  are the lowest values: `VisionCore.Stereo.Stage.MedianFilter`, a
  stage to add for a wider window, documents what that means.

  Natively (`VisionCore.Stereo.NativeSegment`), it matches with
  `NxStereo.sgm/3`'s results, faster on a CPU than the compiled Nx, as
  on a Raspberry Pi 5. It keeps its name, settings and outputs.

  ## Settings

  `NxStereo.Stage.Disparity.settings/0` declares them, with their defaults
  and the values they take; those of a type the vision parameters hold
  are this stage's parameters (`VisionCore.Stereo.NxStage`).

  `:matcher` — `:native` matches natively, `:nx` compiles
  `NxStereo.sgm/3`, whatever the pipeline's `:compute`; by default, as
  the pipeline's `:compute` says. The pipeline's own `compute:` option,
  which any Nx stage takes, does the same: given beside `:matcher`, it
  must agree.
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.Disparity

  alias VisionCore.Stereo.NxStage
  alias VisionCore.Stereo.Pair

  # NxStereo.sgm/3's Census window, 9x7: the border it cannot match.
  @census_width 9
  @census_height 7

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Matches the rectified pair into a disparity with semi-global matching."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "The core of stereo: for each pixel of the left image, it finds the same point in the " <>
        "right image, along the same row. The shift between the two, the disparity, is larger " <>
        "for nearer things. Semi-global matching compares the small patterns around pixels " <>
        "and makes neighbouring pixels agree, except across edges. p1 and p2 penalise small " <>
        "and large disparity changes between neighbours: higher values give smoother surfaces " <>
        "and blurrier edges. uniqueness drops pixels whose best match is not clearly better " <>
        "than the next, as on repetitive patterns. A 3 × 3 median filter ends the stage and " <>
        "removes isolated wrong pixels. Fixed in the build, num_disparities is the " <>
        "search range, which sets the nearest distance measured, and more paths leave fewer " <>
        "holes but take longer. search coarse_to_fine matches a half-size pair first, then " <>
        "refines each pixel near that match at full size: much faster, with nearly the same " <>
        "depth, though a pole or cable too thin for the half-size pair can be missed. Watch " <>
        "Matched pixels and Jitter under the depth video."

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity, :disparity_range]

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    # The half-size match takes the full match's paths unless given its own.
    paths =
      Keyword.get_lazy(opts, :paths, fn -> NxStereo.Stage.Disparity.settings()[:paths].default end)

    NxStage.init_stage(NxStereo.Stage.Disparity, option_specs(), opts, context, %{
      coarse_paths: paths
    })
  end

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, state) do
    %{
      pair
      | disparity: outputs.disparity,
        disparity_scale: 1.0,
        disparity_range: %{
          min_disparity: 0,
          num_disparities: state.num_disparities,
          block_size: @census_width,
          block_height: @census_height
        }
    }
  end
end
