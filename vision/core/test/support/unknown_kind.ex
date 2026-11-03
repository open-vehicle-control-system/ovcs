defmodule VisionCore.Stereo.UnknownKind do
  @moduledoc """
  A stage of a native kind the `stereo_match` Port has no implementation
  of, `:unknown_kind`, which passes the disparity through.
  """
  @behaviour VisionCore.Stereo.NxStage

  @impl VisionCore.Stereo.NxStage
  def init(_opts, _context), do: {:ok, nil}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def step(tensors, _params, _state), do: tensors

  @impl VisionCore.Stereo.NxStage
  def native_kind, do: "no_such_stage"
end
