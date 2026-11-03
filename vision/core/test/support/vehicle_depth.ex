defmodule VisionCore.Stereo.VehicleDepth do
  @moduledoc """
  A vehicle's own depth stage, `:vehicle_depth`:
  `VisionCore.Stereo.Stage.Depth` under another name, which declares the
  core stage's native kind, so that the `stereo_match` Port computes it
  as that stage.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Stage.Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate init(opts, context), to: Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate requires(), to: Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate provides(), to: Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate params(state, context), to: Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate device_only(), to: Depth

  @impl VisionCore.Stereo.NxStage
  defdelegate finish(pair, outputs, state), to: Depth

  @impl VisionCore.Stereo.NxStage
  def native_kind, do: "depth"
end
