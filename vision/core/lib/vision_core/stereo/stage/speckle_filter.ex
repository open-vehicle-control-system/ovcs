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

  ## Options

    * `:min_support` (`12`) — neighbours that must agree, 0 to 48.
    * `:max_diff` (`1.0`) — how close, in pixels, a neighbour must be, 0
      to 8.

  Both change while running.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check

  @radius NxStereo.Stage.SpeckleFilter.native_constants().radius
  @neighbours (2 * @radius + 1) * (2 * @radius + 1) - 1

  @option_specs [
    min_support: %{
      type: :integer,
      range: {0, @neighbours},
      description:
        "Neighbours in the 7x7 window that must agree for a pixel to be kept; 0 turns the filter off"
    },
    max_diff: %{
      type: :double,
      range: {0, 8},
      description: "How close, in pixels, a neighbour's disparity must be to agree"
    }
  ]

  @defaults %{min_support: 12, max_diff: 1.0}

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

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    with {:ok, settings} <- Check.init_settings(@option_specs, @defaults, opts),
         do: NxStereo.Stage.SpeckleFilter.init(Map.to_list(settings), context)
  end

  @impl VisionCore.Stereo.NxStage
  def stereo_stage, do: NxStereo.Stage.SpeckleFilter

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  defdelegate native_kind, to: NxStereo.Stage.SpeckleFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate native_constants, to: NxStereo.Stage.SpeckleFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate params(state, context), to: NxStereo.Stage.SpeckleFilter

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: NxStereo.Stage.SpeckleFilter

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{min_support: state.min_support, max_diff: state.max_diff}

  @impl VisionCore.Stereo.NxStage
  def set_option(state, key, value) do
    with {:ok, value} <- Check.change_setting(@option_specs, options(state), key, value),
         do: {:ok, %{state | key => value}}
  end
end
