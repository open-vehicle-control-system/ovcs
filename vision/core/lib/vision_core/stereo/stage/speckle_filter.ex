defmodule VisionCore.Stereo.Stage.SpeckleFilter do
  @moduledoc """
  Drops speckles, small islands of disparity that agree with nothing
  around them, on the device. A matched pixel is kept when at least
  `:min_support` of the 48 others in its 7x7 neighbourhood matched within
  `:max_diff` pixels of it; the others become unmatched. Isolated blobs
  too small to give their pixels that support are dropped, while
  surfaces keep theirs up to their corners. It plays the part of
  OpenCV's `filterSpeckles`, which labels connected regions instead, a
  poor fit for a GPU.

  ## Settings

  `NxStereo.Stage.SpeckleFilter.settings/0` declares them, with their defaults
  and the values they take; those of a type the vision parameters hold
  are this stage's parameters (`VisionCore.Stereo.NxStage`).
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.SpeckleFilter

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Drops small islands of disparity that agree with nothing around them."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Removes speckles: small islands of disparity that agree with nothing around them, " <>
        "usually false matches on reflections or fine repeated patterns. A pixel is kept when " <>
        "at least min_support of its neighbours have a disparity within max_diff pixels of " <>
        "its own. Raise min_support to remove more islands; too high, and thin objects and " <>
        "the corners of surfaces go too. 0 turns the filter off. Watch the depth video for " <>
        "scattered dots in open space."
end
