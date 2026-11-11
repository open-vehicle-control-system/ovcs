defmodule VisionCore.Stereo.PairCheckTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.PairCheck

  @present %{left: %{present: true}, right: %{present: true}}

  defp window(overrides) do
    Map.merge(
      %{
        cameras: @present,
        sync: %{present: true, pairs: 150, offset_median_ms: 0.08, offset_max_ms: 0.42},
        alignment: %{offset_rows: 0.1, band_offset_rows: [0.1, 0.2, 0.0, 0.1]},
        sharpness: %{left: 0.005, right: 0.0052},
        brightness: %{left: 101.0, right: 98.0},
        row_correction: 0.0
      },
      Map.new(overrides)
    )
  end

  test "a healthy pair has every check ok, pointing at no camera" do
    checks = PairCheck.check(window([]))

    for {_name, check} <- checks, do: assert(%{level: :ok, camera: nil, issues: []} = check)
    assert PairCheck.camera_issues(checks) == %{left: [], right: []}
  end

  test "timing says which camera captures later, and warns past 1 ms" do
    assert %{level: :ok, later: :right, offset_ms: 0.08} = PairCheck.check(window([])).timing

    late = %{present: true, pairs: 150, offset_median_ms: -1.2, offset_max_ms: -2.0}

    assert %{
             level: :warning,
             camera: :left,
             issues: [:timing_offset],
             later: :left,
             offset_ms: 1.2
           } =
             PairCheck.check(window(sync: late)).timing
  end

  test "rows add the correction to what remains, and warn past half a row" do
    rows =
      PairCheck.check(
        window(alignment: %{offset_rows: 0.6, band_offset_rows: [0.6]}, row_correction: -1.3)
      ).rows

    assert %{level: :warning, camera: :right, issues: [:row_offset], direction: :higher} = rows
    assert_in_delta rows.misalignment_rows, 0.7, 1.0e-9
  end

  test "rows warn when the correction moves the right image past 3 rows, or the bands disagree" do
    corrected = PairCheck.check(window(row_correction: 6.0)).rows

    assert %{level: :warning, camera: :right, issues: [:large_row_correction], direction: :lower} =
             corrected

    turned =
      PairCheck.check(
        window(alignment: %{offset_rows: 0.2, band_offset_rows: [0.3, 1.7, -0.1, nil]})
      ).rows

    assert %{issues: [:uneven_rows]} = turned
    assert_in_delta turned.band_spread_rows, 1.8, 1.0e-9

    assert %{level: :ok} = PairCheck.check(window(row_correction: 2.9)).rows
  end

  test "focus points at the softer camera, outside 0.8 to 1.25" do
    soft_right = PairCheck.check(window(sharpness: %{left: 0.0052, right: 0.0032})).focus

    assert %{
             level: :warning,
             camera: :right,
             issues: [:focus_mismatch],
             softer: :right,
             difference_percent: 38
           } =
             soft_right

    assert %{level: :warning, camera: :left, softer: :left} =
             PairCheck.check(window(sharpness: %{left: 0.003, right: 0.005})).focus

    assert %{level: :ok, softer: :right} =
             PairCheck.check(window(sharpness: %{left: 0.005, right: 0.0041})).focus
  end

  test "brightness points at the brighter camera, past 20% brighter" do
    hazy_right = PairCheck.check(window(brightness: %{left: 90.0, right: 120.0})).brightness

    assert %{
             level: :warning,
             camera: :right,
             issues: [:brightness_mismatch],
             brighter: :right,
             difference_percent: 33
           } = hazy_right

    assert_in_delta hazy_right.gauge, 1 / 0.6, 1.0e-9

    assert %{level: :warning, camera: :left, brighter: :left} =
             PairCheck.check(window(brightness: %{left: 130.0, right: 100.0})).brightness

    assert %{level: :ok, brighter: :right} =
             PairCheck.check(window(brightness: %{left: 100.0, right: 118.0})).brightness
  end

  test "keeps a raised issue until its figure falls below 0.8 of its threshold" do
    uneven = fn spread ->
      window(alignment: %{offset_rows: 0.0, band_offset_rows: [0.0, spread]})
    end

    raised = PairCheck.check(uneven.(1.05))
    assert raised.rows.issues == [:uneven_rows]

    assert PairCheck.check(uneven.(0.95), raised).rows.issues == [:uneven_rows]
    assert PairCheck.check(uneven.(0.95)).rows.issues == []
    assert PairCheck.check(uneven.(0.75), raised).rows.issues == []
  end

  test "places each check on a gauge, 1 at its threshold, signed toward the camera it concerns" do
    checks =
      PairCheck.check(
        window(
          sync: %{present: true, pairs: 150, offset_median_ms: -0.5, offset_max_ms: -0.8},
          alignment: %{offset_rows: 0.1, band_offset_rows: [0.0, 0.4]},
          row_correction: 6.0,
          sharpness: %{left: 0.005, right: 0.004}
        )
      )

    assert_in_delta checks.timing.gauge, -0.5, 1.0e-9
    assert_in_delta checks.rows.gauge, 2.0, 1.0e-9
    assert_in_delta checks.focus.gauge, 1.0, 1.0e-9
    refute Map.has_key?(PairCheck.check(window(sync: %{present: false})).timing, :gauge)
  end

  test "gathers the issues pointing at each camera" do
    checks =
      PairCheck.check(window(row_correction: 6.0, sharpness: %{left: 0.0052, right: 0.0032}))

    assert PairCheck.camera_issues(checks) == %{
             left: [],
             right: [:large_row_correction, :focus_mismatch]
           }
  end

  test "has nothing to judge without the cameras, their pairs or their measures" do
    absent = %{left: %{present: true}, right: %{present: false}}

    checks =
      PairCheck.check(
        window(
          cameras: absent,
          sync: %{present: false},
          alignment: nil,
          sharpness: nil,
          brightness: nil,
          row_correction: nil
        )
      )

    for {_name, check} <- checks, do: assert(check == %{level: :off, camera: nil, issues: []})
  end

  test "lists every issue it raises" do
    assert PairCheck.issues() ==
             [
               :timing_offset,
               :row_offset,
               :large_row_correction,
               :uneven_rows,
               :focus_mismatch,
               :brightness_mismatch
             ]
  end
end
