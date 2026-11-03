defmodule VisionCore.Stereo.VehicleRectification do
  @moduledoc """
  A vehicle's own rectification stage, `:vehicle_rectification`:
  `VisionCore.Stereo.Stage.Rectification` under another name, for tests of
  what finds a stage by its settings rather than its name.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Stage.Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate init(opts, context), to: Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate requires(), to: Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate provides(), to: Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate native_kind(), to: Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate params(state, context), to: Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate option_specs(), to: Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate options(state), to: Rectification

  @impl VisionCore.Stereo.NxStage
  defdelegate set_option(state, key, value), to: Rectification
end
