defmodule VisionCore.Stereo.Stage.Match do
  @moduledoc """
  Matches the rectified pair with `NxStereo.sgm/3`: libSGM's
  semi-global matching, as compute shaders on a Vulkan GPU through
  `nx_iree`, or compiled for the CPU. The disparity stays in `f32` pixels
  (`disparity_scale` 1.0), -1 where unmatched.

  ## Options

    * `:num_disparities` (64) — 64 or 128.
    * `:p1` (8), `:p2` (64) — penalties for a disparity change of one, and
      of more, between neighbours; `:p2` must exceed `:p1`.
    * `:uniqueness` (1.0526) — a match is kept when the second-best cost
      is at least this factor above the best.
    * `:paths` (8) — aggregation paths, 8 or 3: 3 takes about a quarter of
      the GPU time and leaves more pixels unmatched on dark or textureless
      surfaces.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  # The Census window is 9 pixels wide: the border it cannot match.
  @census_width 9

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context) do
    disparities = Keyword.get(opts, :num_disparities, 64)
    p1 = Keyword.get(opts, :p1, 8)
    p2 = Keyword.get(opts, :p2, 64)
    uniqueness = Keyword.get(opts, :uniqueness, 1.0526315789473684)
    paths = Keyword.get(opts, :paths, 8)

    cond do
      disparities not in [64, 128] ->
        {:error, "nx_stereo searches 64 or 128 disparities, got #{inspect(disparities)}"}

      not (is_integer(p1) and is_integer(p2) and p2 > p1) ->
        {:error, "nx_stereo needs integer penalties with p2 > p1, got #{p1} and #{p2}"}

      paths not in [3, 8] ->
        {:error, "nx_stereo aggregates along 3 or 8 paths, got #{inspect(paths)}"}

      true ->
        {:ok, [disparities: disparities, p1: p1, p2: p2, uniqueness: uniqueness, paths: paths]}
    end
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity, :disparity_range]

  @impl VisionCore.Stereo.NxStage
  def params(_state, _context), do: %{}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, _params, sgm_opts),
    do: Map.put(tensors, :disparity, NxStereo.sgm(tensors.left, tensors.right, sgm_opts))

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, sgm_opts) do
    %{
      pair
      | disparity: outputs.disparity,
        disparity_scale: 1.0,
        disparity_range: %{
          min_disparity: 0,
          num_disparities: sgm_opts[:disparities],
          block_size: @census_width
        }
    }
  end
end
