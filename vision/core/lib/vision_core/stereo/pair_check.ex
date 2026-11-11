defmodule VisionCore.Stereo.PairCheck do
  @moduledoc """
  How well a stereo unit's two cameras work together, judged from a status
  window: their `:timing`, how far apart their captures start, their
  `:rows`, how well the rectified images line up and how far the automatic
  correction moves the right one, and their `:focus`, how sharp each is
  next to the other.

  Each check has a `:level`, `:ok`, `:warning` as soon as it has an issue,
  or `:off` with nothing to judge, the `:camera` its issues point at, or
  `nil`, its `:issues` (`issues/0`), its `:gauge`, and its figures, with
  the camera or direction each concerns already worked out, so a reader
  computes nothing. The gauge is where the check stands against its
  threshold: 0 at best, 1 at the threshold, negative toward the left
  camera and positive toward the right. `camera_issues/1` gathers the issues pointing at each camera.

  An issue is raised past its threshold and, once raised, stays until its
  figure falls below `0.8` of it: given the previous window's checks, a
  figure hovering at a threshold does not raise and clear the issue in
  turn.
  """

  @timing_offset :timing_offset
  @row_offset :row_offset
  @large_row_correction :large_row_correction
  @uneven_rows :uneven_rows
  @focus_mismatch :focus_mismatch

  @issues [@timing_offset, @row_offset, @large_row_correction, @uneven_rows, @focus_mismatch]

  # Thresholds past which a check warns.
  @max_timing_offset_ms 1.0
  @max_row_offset_rows 0.5
  @max_row_correction_rows 3.0
  @max_band_spread_rows 1.0
  # How much sharper the sharper camera may be than the other, as a fraction.
  @max_focus_gap 0.25
  # A raised issue clears only below this share of its threshold, so a value near it does not flap.
  @clear_ratio 0.8

  @typedoc "What a check found wrong."
  @type issue ::
          :timing_offset | :row_offset | :large_row_correction | :uneven_rows | :focus_mismatch

  @type side :: :left | :right
  @type level :: :ok | :warning | :off
  @type check :: %{
          required(:level) => level(),
          required(:camera) => side() | nil,
          required(:issues) => [issue()],
          optional(atom()) => term()
        }
  @type t :: %{timing: check(), rows: check(), focus: check()}

  @doc "Every issue a check can raise."
  @spec issues() :: [issue()]
  def issues, do: @issues

  @doc """
  The checks of a status window: `:cameras`, each side's `:present`,
  `:sync` (`VisionCore.Stereo.Pairer.sync/1`, `:present` added),
  `:alignment` and `:sharpness`, the window's means, and
  `:row_correction`, the rows the right image is moved by, `nil` without
  a stage to move them; `previous` is the previous window's checks.
  """
  @spec check(map(), t() | nil) :: t()
  def check(window, previous \\ nil) do
    raised = raised(previous)

    %{
      timing: timing(window.cameras, window.sync, raised),
      rows: rows(window.alignment, window.row_correction, raised),
      focus: focus(window.cameras, window.sharpness, raised)
    }
  end

  defp raised(nil), do: MapSet.new()

  defp raised(previous),
    do: MapSet.new(for {_name, %{issues: issues}} <- previous, issue <- issues, do: issue)

  # Past `limit`, or, for an issue already raised, past its clearing point.
  defp past?(value, limit, issue, raised) do
    if MapSet.member?(raised, issue), do: value > limit * @clear_ratio, else: value > limit
  end

  @doc "The issues of `checks` pointing at each camera."
  @spec camera_issues(t()) :: %{left: [issue()], right: [issue()]}
  def camera_issues(checks) do
    pointing = fn side ->
      for name <- [:timing, :rows, :focus],
          %{camera: ^side, issues: issues} <- [checks[name]],
          issue <- issues,
          do: issue
    end

    %{left: pointing.(:left), right: pointing.(:right)}
  end

  # The offset is right minus left: positive when the right capture starts later.
  defp timing(
         %{left: %{present: true}, right: %{present: true}},
         %{offset_median_ms: offset} = sync,
         raised
       )
       when is_number(offset) do
    later = if offset >= 0, do: :right, else: :left

    issues =
      if past?(abs(offset), @max_timing_offset_ms, @timing_offset, raised),
        do: [@timing_offset],
        else: []

    judged(issues, later, %{
      gauge: offset / @max_timing_offset_ms,
      later: later,
      offset_ms: abs(offset),
      max_offset_ms: sync.offset_max_ms && abs(sync.offset_max_ms),
      pairs: sync.pairs
    })
  end

  defp timing(_cameras, _sync, _raised), do: off()

  # A positive offset is the right image's match sitting lower; the correction moves the right image.
  defp rows(%{offset_rows: offset} = alignment, correction, raised) when is_number(offset) do
    correction = correction || 0.0
    misalignment = offset + correction
    bands = Enum.filter(alignment.band_offset_rows, &is_number/1)
    spread = if bands == [], do: 0.0, else: Enum.max(bands) - Enum.min(bands)

    issues =
      Enum.filter(
        [
          past?(abs(offset), @max_row_offset_rows, @row_offset, raised) && @row_offset,
          past?(abs(correction), @max_row_correction_rows, @large_row_correction, raised) &&
            @large_row_correction,
          past?(spread, @max_band_spread_rows, @uneven_rows, raised) && @uneven_rows
        ],
        & &1
      )

    gauge =
      Enum.max([
        abs(offset) / @max_row_offset_rows,
        abs(correction) / @max_row_correction_rows,
        spread / @max_band_spread_rows
      ])

    judged(issues, :right, %{
      gauge: gauge,
      direction: if(misalignment >= 0, do: :lower, else: :higher),
      misalignment_rows: abs(misalignment),
      offset_rows: offset,
      correction_rows: correction,
      band_offset_rows: alignment.band_offset_rows,
      band_spread_rows: spread
    })
  end

  defp rows(_alignment, _correction, _raised), do: off()

  defp focus(
         %{left: %{present: true}, right: %{present: true}},
         %{left: left, right: right},
         raised
       )
       when is_number(left) and is_number(right) and left > 0 and right > 0 do
    ratio = right / left
    softer = if ratio < 1, do: :right, else: :left

    gap = max(ratio, 1 / ratio) - 1

    issues =
      if past?(gap, @max_focus_gap, @focus_mismatch, raised), do: [@focus_mismatch], else: []

    judged(issues, softer, %{
      gauge: if(softer == :right, do: gap, else: -gap) / @max_focus_gap,
      softer: softer,
      difference_percent: round(100 * (1 - min(ratio, 1 / ratio))),
      ratio: ratio,
      left: left,
      right: right
    })
  end

  defp focus(_cameras, _sharpness, _raised), do: off()

  defp judged([], _camera, figures),
    do: Map.merge(%{level: :ok, camera: nil, issues: []}, figures)

  defp judged(issues, camera, figures),
    do: Map.merge(%{level: :warning, camera: camera, issues: issues}, figures)

  defp off, do: %{level: :off, camera: nil, issues: []}
end
