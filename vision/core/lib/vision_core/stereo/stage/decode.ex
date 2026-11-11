defmodule VisionCore.Stereo.Stage.Decode do
  @moduledoc """
  Turns both camera frames into images at the pipeline's size: grey
  frames as they are, JPEG frames decoded to their luma
  (`VisionCore.Camera.Frame.to_tensor/1`), shrunk by area averaging when
  larger, so the matcher can work on fewer pixels than the cameras
  deliver. For stage lists without `VisionCore.Stereo.Stage.Rectification`,
  which shrinks the frames itself.
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.Decode

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Turns both camera frames into grey images at the pipeline's size."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Turns both camera frames into grey images at the matching size, without correcting " <>
        "the lenses. It takes Rectification's place in a stage list without it, for frames " <>
        "that need no correction; matching then works only as far as the cameras are already " <>
        "aligned. It has no settings."
end
