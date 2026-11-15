defmodule VisionCore.Stereo.PairCheck do
  @moduledoc """
  How well a stereo unit's two cameras work together, judged from a status
  window: their `:timing`, how far apart their captures start, their
  `:rows`, how far the rectified images' rows sit apart after the row
  correction and how far it moves the right image, their `:rotation`, how
  the rows' offset changes across the image, their `:focus`, how sharp
  each is next to the other, and their `:brightness`, how bright each
  image is next to the other at the same exposure and gain.

  Each figure is what the stereo matching sees, after every correction;
  the row correction itself is a figure of `:rows`.

  Each check is a `VisionCore.Stereo.Check`, with its `:issues`
  (`issues/0`), its `:gauge`, and its figures, the camera or direction
  each concerns already worked out, so a reader computes nothing. The
  gauge is where the check stands against its threshold: 0 at best, 1 at
  the threshold, negative toward the left camera and positive toward the
  right. `camera_issues/1` gathers the issues pointing at each camera.
  """

  @timing_offset :timing_offset
  @row_offset :row_offset
  @large_row_correction :large_row_correction
  @rotation_mismatch :rotation_mismatch
  @focus_mismatch :focus_mismatch
  @brightness_mismatch :brightness_mismatch

  @issues [
    @timing_offset,
    @row_offset,
    @large_row_correction,
    @rotation_mismatch,
    @focus_mismatch,
    @brightness_mismatch
  ]
  @checks [:timing, :rows, :rotation, :focus, :brightness]

  # Thresholds past which a check warns.
  @max_timing_offset_ms 1.0
  @max_row_offset_rows 0.5
  @max_row_correction_rows 3.0
  @max_band_spread_rows 1.0
  # How much sharper the sharper camera may be than the other, as a fraction.
  @max_focus_gap 0.25
  # How much brighter the brighter camera may be than the other, as a fraction.
  @max_brightness_gap 0.2

  alias VisionCore.Stereo.Check

  @typedoc "What a check found wrong."
  @type issue ::
          :timing_offset
          | :row_offset
          | :large_row_correction
          | :rotation_mismatch
          | :focus_mismatch
          | :brightness_mismatch

  @type t :: %{
          timing: Check.t(),
          rows: Check.t(),
          rotation: Check.t(),
          focus: Check.t(),
          brightness: Check.t()
        }

  @doc "Every issue a check can raise."
  @spec issues() :: [issue()]
  def issues, do: @issues

  @doc """
  The checks of a status window: `:cameras`, each side's `:present`,
  `:sync` (`VisionCore.Stereo.Pairer.sync/1`, `:present` added),
  `:alignment`, `:sharpness` and `:brightness`, the window's means, and
  `:row_correction`, the rows the right image is moved by, `nil` without
  a stage to move them; `previous` is the previous window's checks.
  """
  @spec check(map(), t() | nil) :: t()
  def check(window, previous \\ nil) do
    raised = Check.raised(previous)

    %{
      timing: timing(window.cameras, window.sync, raised),
      rows: rows(window.alignment, window.row_correction, raised),
      rotation: rotation(window.alignment, raised),
      focus: focus(window.cameras, window.sharpness, raised),
      brightness: brightness(window.cameras, window.brightness, raised)
    }
  end

  @doc "The issues of `checks` pointing at each camera."
  @spec camera_issues(t()) :: %{left: [issue()], right: [issue()]}
  def camera_issues(checks) do
    pointing = fn side ->
      for name <- @checks,
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
      if Check.past?(abs(offset), @max_timing_offset_ms, @timing_offset, raised),
        do: [@timing_offset],
        else: []

    Check.judged(issues, later, %{
      gauge: offset / @max_timing_offset_ms,
      later: later,
      offset_ms: abs(offset),
      max_offset_ms: sync.offset_max_ms && abs(sync.offset_max_ms),
      pairs: sync.pairs
    })
  end

  defp timing(_cameras, _sync, _raised), do: Check.off()

  # The offset is measured once the correction has moved the right image, which a positive one moves up.
  defp rows(%{offset_rows: offset}, correction, raised) when is_number(offset) do
    correction = correction || 0.0

    issues =
      Enum.filter(
        [
          Check.past?(abs(offset), @max_row_offset_rows, @row_offset, raised) && @row_offset,
          Check.past?(abs(correction), @max_row_correction_rows, @large_row_correction, raised) &&
            @large_row_correction
        ],
        & &1
      )

    Check.judged(issues, :right, %{
      gauge: max(abs(offset) / @max_row_offset_rows, abs(correction) / @max_row_correction_rows),
      residual_rows: abs(offset),
      correction_rows: abs(correction),
      correction_direction: correction_direction(correction)
    })
  end

  defp rows(_alignment, _correction, _raised), do: Check.off()

  defp correction_direction(correction) when correction > 0, do: :up
  defp correction_direction(correction) when correction < 0, do: :down
  defp correction_direction(_none), do: nil

  # Offsets that change across the bands are a rotation no row correction undoes.
  defp rotation(%{band_offset_rows: bands}, raised) do
    measured = for {offset, band} <- Enum.with_index(bands), is_number(offset), do: {band, offset}

    if length(measured) < 2 do
      Check.off()
    else
      offsets = Enum.map(measured, &elem(&1, 1))
      spread = Enum.max(offsets) - Enum.min(offsets)

      issues =
        if Check.past?(spread, @max_band_spread_rows, @rotation_mismatch, raised),
          do: [@rotation_mismatch],
          else: []

      Check.judged(issues, :right, %{
        gauge: spread / @max_band_spread_rows,
        band_spread_rows: spread,
        band_offset_rows: bands,
        turned: turn(slope(measured))
      })
    end
  end

  defp rotation(_alignment, _raised), do: Check.off()

  # The least-squares slope of the offsets over the bands, in rows a band.
  defp slope(points) do
    count = length(points)
    mean_band = Enum.sum(Enum.map(points, &elem(&1, 0))) / count
    mean_offset = Enum.sum(Enum.map(points, &elem(&1, 1))) / count

    covariance =
      Enum.sum(for {band, offset} <- points, do: (band - mean_band) * (offset - mean_offset))

    variance = Enum.sum(for {band, _offset} <- points, do: (band - mean_band) ** 2)
    covariance / variance
  end

  # Rows sitting lower toward the right edge turn the right image clockwise on screen.
  defp turn(slope) when slope > 0, do: :clockwise
  defp turn(slope) when slope < 0, do: :counterclockwise
  defp turn(_level), do: nil

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
      if Check.past?(gap, @max_focus_gap, @focus_mismatch, raised),
        do: [@focus_mismatch],
        else: []

    Check.judged(issues, softer, %{
      gauge: if(softer == :right, do: gap, else: -gap) / @max_focus_gap,
      softer: softer,
      difference_percent: round(100 * (1 - min(ratio, 1 / ratio))),
      ratio: ratio,
      left: left,
      right: right
    })
  end

  defp focus(_cameras, _sharpness, _raised), do: Check.off()

  # A camera brighter than the other at the same exposure and gain sees differently, as through a hazy lens.
  defp brightness(
         %{left: %{present: true}, right: %{present: true}},
         %{left: left, right: right},
         raised
       )
       when is_number(left) and is_number(right) and left > 0 and right > 0 do
    ratio = right / left
    brighter = if ratio > 1, do: :right, else: :left
    gap = max(ratio, 1 / ratio) - 1

    issues =
      if Check.past?(gap, @max_brightness_gap, @brightness_mismatch, raised),
        do: [@brightness_mismatch],
        else: []

    Check.judged(issues, brighter, %{
      gauge: if(brighter == :right, do: gap, else: -gap) / @max_brightness_gap,
      brighter: brighter,
      difference_percent: round(100 * gap),
      left: left,
      right: right
    })
  end

  defp brightness(_cameras, _brightness, _raised), do: Check.off()
end
