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
  `NxStereo.sgm/3`'s results, many times faster on a CPU than the
  compiled Nx, as on a Raspberry Pi 5. It keeps its name, settings and
  outputs.

  ## Options

    * `:num_disparities` (64) — 64 or 128.
    * `:p1` (8), `:p2` (64) — penalties for a disparity change of one, and
      of more, between neighbours: integers up to 79, `:p2` above `:p1`.
    * `:uniqueness` (1.0526, `NxStereo.sgm/3`'s default) — a match is
      kept when the second-best cost is at least this factor above the
      best, 1 to 3.
    * `:paths` (8) — aggregation paths, 8 or 3: 3 takes much less time
      and leaves more pixels unmatched on dark or textureless surfaces.
    * `:matcher` — `:native` matches natively, `:nx` compiles
      `NxStereo.sgm/3`, whatever the pipeline's `:compute`; by default,
      as the pipeline's `:compute` says.

  `:p1`, `:p2` and `:uniqueness` are inputs of the compiled function, so
  they also change while running; `:num_disparities` and `:paths` are
  fixed in it (`option_specs/0`).
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check
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

  @defaults %{p1: 8, p2: 64, uniqueness: 1.0526315789473684, num_disparities: 64, paths: 8}

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
        "holes but take longer. Watch Matched pixels and Jitter under the depth video."

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context) do
    {matcher, opts} = Keyword.pop(opts, :matcher)

    with :ok <- check_matcher(matcher),
         {:ok, settings} <- Check.init_settings(@option_specs, @defaults, opts),
         do: {:ok, Map.put(settings, :matcher, matcher)}
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity, :disparity_range]

  @impl VisionCore.Stereo.NxStage
  def params(state, _context), do: Map.take(state, @live)

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, state) do
    disparity =
      NxStereo.sgm(tensors.left, tensors.right,
        disparities: state.num_disparities,
        paths: state.paths,
        p1: params.p1,
        p2: params.p2,
        uniqueness: params.uniqueness
      )

    Map.put(tensors, :disparity, Nx.select(Nx.greater(disparity, 0), disparity, -1.0))
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
          block_size: @census_width
        }
    }
  end

  @impl VisionCore.Stereo.NxStage
  def compute(state), do: state.matcher

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: Map.delete(state, :matcher)

  @impl VisionCore.Stereo.NxStage
  def set_option(state, key, value) do
    with {:ok, value} <- Check.change_setting(@option_specs, options(state), key, value),
         do: {:ok, %{state | key => value}}
  end

  # The matcher is an option, not a setting: it picks how the disparity is computed.
  defp check_matcher(matcher) when matcher in [nil, :nx, :native], do: :ok

  defp check_matcher(matcher),
    do: {:error, "matcher must be :nx or :native, got #{inspect(matcher)}"}
end
