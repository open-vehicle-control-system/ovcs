defmodule VisionCore.Stereo.Stage.Decode do
  @moduledoc """
  Turns both camera frames into images at the pipeline's size: grey
  frames as they are, JPEG frames decoded to their luma
  (`VisionCore.Camera.Frame.to_tensor/1`), shrunk by area averaging when
  larger, so the matcher can work on fewer pixels than the cameras
  deliver.
  """
  @behaviour VisionCore.Stereo.NxStage

  @impl VisionCore.Stereo.NxStage
  def init(_opts, context), do: {:ok, %{size: {context.height, context.width}}}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left_frame, :right_frame]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def params(_state, _context), do: %{}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, _params, %{size: size}) do
    tensors
    |> Map.put(:left, NxStereo.Image.resize_area(tensors.left_frame, size))
    |> Map.put(:right, NxStereo.Image.resize_area(tensors.right_frame, size))
  end
end
