defmodule VisionCore.Stereo.PairCheck do
  @moduledoc """
  How well a stereo unit's two cameras work together, judged from a status
  window: their `:timing`, how far apart their captures start, their
  `:rows`, how well the rectified images line up and how far the automatic
  correction moves the right one, their `:focus`, how sharp each is next
  to the other, and their `:brightness`, how bright each image is next to
  the other at the same exposure and gain.

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
  @uneven_rows :uneven_rows
  @focus_mismatch :focus_mismatch
  @brightness_mismatch :brightness_mismatch

  @issues [
    @timing_offset,
    @row_offset,
    @large_row_correction,
    @uneven_rows,
    @focus_mismatch,
    @brightness_mismatch
  ]
  @checks [:timing, :rows, :focus, :brightness]

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
          | :uneven_rows
          | :focus_mismatch
          | :brightness_mismatch

  @type t :: %{timing: Check.t(), rows: Check.t(), focus: Check.t(), brightness: Check.t()}

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

  # A positive offset is the right image's match sitting lower; the correction moves the right image.
  defp rows(%{offset_rows: offset} = alignment, correction, raised) when is_number(offset) do
    correction = correction || 0.0
    misalignment = offset + correction
    bands = Enum.filter(alignment.band_offset_rows, &is_number/1)
    spread = if bands == [], do: 0.0, else: Enum.max(bands) - Enum.min(bands)

    issues =
      Enum.filter(
        [
          Check.past?(abs(offset), @max_row_offset_rows, @row_offset, raised) && @row_offset,
          Check.past?(abs(correction), @max_row_correction_rows, @large_row_correction, raised) &&
            @large_row_correction,
          Check.past?(spread, @max_band_spread_rows, @uneven_rows, raised) && @uneven_rows
        ],
        & &1
      )

    gauge =
      Enum.max([
        abs(offset) / @max_row_offset_rows,
        abs(correction) / @max_row_correction_rows,
        spread / @max_band_spread_rows
      ])

    Check.judged(issues, :right, %{
      gauge: gauge,
      direction: if(misalignment >= 0, do: :lower, else: :higher),
      misalignment_rows: abs(misalignment),
      offset_rows: offset,
      correction_rows: correction,
      band_offset_rows: alignment.band_offset_rows,
      band_spread_rows: spread
    })
  end

  defp rows(_alignment, _correction, _raised), do: Check.off()

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
