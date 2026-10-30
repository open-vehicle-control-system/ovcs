defmodule VisionCore.Stereo.Stage.Disparity do
  @moduledoc """
  Matches the rectified pair with `NxStereo.sgm/3`: libSGM's
  semi-global matching, as compute shaders on a Vulkan GPU through
  `nx_iree`, or compiled for the CPU. The disparity stays in `f32` pixels
  (`disparity_scale` 1.0), -1 where unmatched.

  ## Options

    * `:num_disparities` (64) — 64 or 128.
    * `:p1` (8), `:p2` (64) — penalties for a disparity change of one, and
      of more, between neighbours: integers up to 79, `:p2` above `:p1`.
    * `:uniqueness` (1.0526) — a match is kept when the second-best cost
      is at least this factor above the best.
    * `:paths` (8) — aggregation paths, 8 or 3: 3 takes about a quarter of
      the GPU time and leaves more pixels unmatched on dark or textureless
      surfaces.

  `:p1`, `:p2` and `:uniqueness` are inputs of the compiled function, so
  they also change while running; `:num_disparities` and `:paths` are
  fixed in it (`option_specs/0`).
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  # The Census window is 9 pixels wide: the border it cannot match.
  @census_width 9
  # Path costs are bytes in the shaders: NxStereo.sgm/3 bounds P2 so they cannot overflow.
  @max_penalty 79

  @live [:p1, :p2, :uniqueness]

  @option_specs [
    p1: %{
      type: :integer,
      range: {0, @max_penalty - 1},
      description: "Penalty for a disparity change of one between neighbours"
    },
    p2: %{
      type: :integer,
      range: {1, @max_penalty},
      greater_than: :p1,
      description: "Penalty for a larger disparity change; above p1"
    },
    uniqueness: %{
      type: :double,
      range: {1, 3},
      description: "Factor the second-best cost must exceed the best by"
    },
    num_disparities: %{
      type: :integer,
      values: [64, 128],
      applies: :build,
      description: "Disparities searched, from 0"
    },
    paths: %{
      type: :integer,
      values: [3, 8],
      applies: :build,
      description: "Aggregation paths; 3 is faster and leaves more pixels unmatched"
    }
  ]

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Matches the rectified pair into a disparity with semi-global matching."

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

      paths not in [3, 8] ->
        {:error, "nx_stereo aggregates along 3 or 8 paths, got #{inspect(paths)}"}

      true ->
        validate(disparities: disparities, paths: paths, p1: p1, p2: p2, uniqueness: uniqueness)
    end
  end

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(sgm_opts) do
    sgm_opts
    |> live()
    |> Map.merge(%{num_disparities: sgm_opts[:disparities], paths: sgm_opts[:paths]})
  end

  @impl VisionCore.Stereo.NxStage
  def set_option(sgm_opts, key, value) when key in @live,
    do: validate(Keyword.put(sgm_opts, key, value))

  defp validate(sgm_opts) do
    {p1, p2, uniqueness} = {sgm_opts[:p1], sgm_opts[:p2], sgm_opts[:uniqueness]}

    cond do
      not (is_integer(p1) and is_integer(p2) and p1 in 0..@max_penalty and
               p2 in 0..@max_penalty) ->
        {:error, "p1 and p2 must be integers from 0 to #{@max_penalty}, got #{p1} and #{p2}"}

      p2 <= p1 ->
        {:error, "p2 must exceed p1, got #{p1} and #{p2}"}

      not (is_number(uniqueness) and uniqueness >= 1) ->
        {:error, "uniqueness must be at least 1, got #{inspect(uniqueness)}"}

      true ->
        {:ok, Keyword.put(sgm_opts, :uniqueness, uniqueness * 1.0)}
    end
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity, :disparity_range]

  @impl VisionCore.Stereo.NxStage
  def params(sgm_opts, _context), do: live(sgm_opts)

  defp live(sgm_opts), do: Map.new(Keyword.take(sgm_opts, @live))

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, sgm_opts) do
    sgm_opts = Keyword.merge(sgm_opts, Map.to_list(params))
    Map.put(tensors, :disparity, NxStereo.sgm(tensors.left, tensors.right, sgm_opts))
  end

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
