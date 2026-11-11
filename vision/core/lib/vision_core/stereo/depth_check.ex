defmodule VisionCore.Stereo.DepthCheck do
  @moduledoc """
  How well a stereo unit turns its pairs into depth, judged from a status
  window: its `:rate`, the share of the cameras' pairs it drops, and its
  `:range`, the share of what it matches in the nearest band it can see,
  where objects nearer than it can measure show.

  Each check is a `VisionCore.Stereo.Check`, pointing at no camera, with
  its `:issues` (`issues/0`), its `:gauge`, 0 at best and 1 at the
  threshold, and its figures, so a reader computes nothing.
  """

  alias VisionCore.Stereo.Check

  @pairs_dropped :pairs_dropped
  @too_near :too_near

  @issues [@pairs_dropped, @too_near]

  # Thresholds past which a check warns.
  @max_dropped_percent 5.0
  @max_near_percent 15.0
  # The nearest band: matches within this share of the top of the disparity range.
  @near_band 0.15
  # One disparity pixel in this many, along each axis, is read for the near share.
  @sample_stride 8

  @typedoc "What a check found wrong."
  @type issue :: :pairs_dropped | :too_near
  @type t :: %{rate: Check.t(), range: Check.t()}

  @doc "Every issue a check can raise."
  @spec issues() :: [issue()]
  def issues, do: @issues

  @doc """
  The checks of a status window: `:cameras`, each side's `:present` and
  `:fps`, `:depth_hz`, `:load_percent`, the stereo segment's busy share,
  and `:near`, `near/1` of the window's last pair, or `nil`; `previous` is
  the previous window's checks.
  """
  @spec check(map(), t() | nil) :: t()
  def check(window, previous \\ nil) do
    raised = Check.raised(previous)

    %{
      rate: rate(window.cameras, window.depth_hz, window.load_percent, raised),
      range: range(window.near, raised)
    }
  end

  @doc """
  How near a pair's depth reaches: the share of its matched disparity
  pixels in the nearest band, read one pixel in 8 along each axis, and
  the nearest depth its range measures, in metres; `nil` without a
  disparity, its range or its geometry.
  """
  @spec near(VisionCore.Stereo.Pair.t()) :: %{near_percent: float(), nearest_m: float()} | nil
  def near(%{
        disparity: %Nx.Tensor{} = disparity,
        disparity_scale: scale,
        disparity_range: %{} = range,
        geometry: %{focal_length_px: focal_length, baseline_m: baseline}
      }) do
    top = range.min_disparity + range.num_disparities
    near_from = (top - @near_band * range.num_disparities) / (scale || 1.0)
    {height, width} = Nx.shape(disparity)

    sampled =
      Nx.slice(disparity, [0, 0], [height, width], strides: [@sample_stride, @sample_stride])

    matched = sampled |> Nx.greater(0) |> Nx.sum() |> Nx.to_number()
    near = sampled |> Nx.greater_equal(near_from) |> Nx.sum() |> Nx.to_number()

    %{
      near_percent: if(matched > 0, do: 100 * near / matched, else: 0.0),
      nearest_m: focal_length * baseline / top
    }
  end

  def near(_pair), do: nil

  # Pairs the cameras deliver, at the slower one's rate, that do not become depth.
  defp rate(
         %{left: %{present: true, fps: left}, right: %{present: true, fps: right}},
         depth_hz,
         load,
         raised
       )
       when is_number(left) and is_number(right) and left > 0 and right > 0 do
    camera_hz = min(left, right)
    dropped = max(0.0, 100 * (1 - depth_hz / camera_hz))

    issues =
      if Check.past?(dropped, @max_dropped_percent, @pairs_dropped, raised),
        do: [@pairs_dropped],
        else: []

    Check.judged(issues, nil, %{
      gauge: dropped / @max_dropped_percent,
      dropped_percent: dropped,
      depth_hz: depth_hz,
      camera_hz: camera_hz,
      load_percent: load
    })
  end

  defp rate(_cameras, _depth_hz, _load, _raised), do: Check.off()

  defp range(%{near_percent: near, nearest_m: nearest}, raised) do
    issues = if Check.past?(near, @max_near_percent, @too_near, raised), do: [@too_near], else: []

    Check.judged(issues, nil, %{
      gauge: near / @max_near_percent,
      near_percent: near,
      nearest_m: nearest
    })
  end

  defp range(_near, _raised), do: Check.off()
end
