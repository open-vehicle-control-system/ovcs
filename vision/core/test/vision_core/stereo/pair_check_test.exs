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

  test "rows give the offset left after the correction, and the correction's move of the right image" do
    # The OVCS Mini: a 0.80-row correction leaves -0.05, the bands spread by a rotation.
    rows =
      PairCheck.check(
        window(
          alignment: %{offset_rows: -0.05, band_offset_rows: [-0.32, 0.4, 1.2, 1.97]},
          row_correction: 0.8
        )
      ).rows

    assert %{level: :ok, camera: nil, issues: [], correction_direction: :up} = rows
    assert_in_delta rows.residual_rows, 0.05, 1.0e-9
    assert_in_delta rows.correction_rows, 0.8, 1.0e-9
    refute Map.has_key?(rows, :band_spread_rows)
  end

  test "rows say which way the correction moves the right image, none without one" do
    assert %{correction_direction: :down, correction_rows: 1.3} =
             PairCheck.check(window(row_correction: -1.3)).rows

    assert %{correction_direction: nil, correction_rows: +0.0} =
             PairCheck.check(window(row_correction: 0.0)).rows

    assert %{correction_direction: nil, correction_rows: +0.0} =
             PairCheck.check(window(row_correction: nil)).rows
  end

  test "rows warn past half a row left after the correction, or a correction past 3 rows" do
    apart =
      PairCheck.check(window(alignment: %{offset_rows: -0.6, band_offset_rows: [-0.6]})).rows

    assert %{level: :warning, camera: :right, issues: [:row_offset]} = apart
    assert_in_delta apart.residual_rows, 0.6, 1.0e-9

    assert %{level: :warning, camera: :right, issues: [:large_row_correction]} =
             PairCheck.check(window(row_correction: 6.0)).rows

    assert %{level: :ok} = PairCheck.check(window(row_correction: 2.9)).rows
  end

  test "rotation warns when the bands are more than a row apart, the right image turned" do
    turned =
      PairCheck.check(
        window(alignment: %{offset_rows: 0.2, band_offset_rows: [0.3, 1.7, -0.1, nil]})
      )

    assert %{level: :warning, camera: :right, issues: [:rotation_mismatch]} = turned.rotation
    assert_in_delta turned.rotation.band_spread_rows, 1.8, 1.0e-9
    assert turned.rotation.band_offset_rows == [0.3, 1.7, -0.1, nil]
    assert %{level: :ok, issues: []} = turned.rows
  end

  test "rotation says which way the right image is turned on screen, from the bands' slope" do
    falling_right =
      window(alignment: %{offset_rows: 0.0, band_offset_rows: [-0.32, 0.4, 1.2, 1.97]})

    rising_right = window(alignment: %{offset_rows: 0.0, band_offset_rows: [0.5, nil, -0.5]})

    assert %{turned: :clockwise} = PairCheck.check(falling_right).rotation
    assert %{turned: :counterclockwise} = PairCheck.check(rising_right).rotation

    assert %{turned: nil} =
             PairCheck.check(window(alignment: %{offset_rows: 0.0, band_offset_rows: [0.2, 0.2]})).rotation
  end

  test "rotation has nothing to judge with fewer than two measured bands" do
    one_band = window(alignment: %{offset_rows: 0.1, band_offset_rows: [nil, 0.1, nil, nil]})

    assert PairCheck.check(one_band).rotation == %{level: :off, camera: nil, issues: []}
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
    rotated = fn spread ->
      window(alignment: %{offset_rows: 0.0, band_offset_rows: [0.0, spread]})
    end

    raised = PairCheck.check(rotated.(1.05))
    assert raised.rotation.issues == [:rotation_mismatch]

    assert PairCheck.check(rotated.(0.95), raised).rotation.issues == [:rotation_mismatch]
    assert PairCheck.check(rotated.(0.95)).rotation.issues == []
    assert PairCheck.check(rotated.(0.75), raised).rotation.issues == []
  end

  test "places rows on its gauge by its own measures only, not by the bands" do
    rows =
      PairCheck.check(
        window(alignment: %{offset_rows: 0.1, band_offset_rows: [-1.0, 1.0]}, row_correction: 0.0)
      ).rows

    assert_in_delta rows.gauge, 0.2, 1.0e-9
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
    assert_in_delta checks.rotation.gauge, 0.4, 1.0e-9
    assert_in_delta checks.focus.gauge, 1.0, 1.0e-9
    refute Map.has_key?(PairCheck.check(window(sync: %{present: false})).timing, :gauge)
  end

  test "gathers the issues pointing at each camera" do
    checks =
      PairCheck.check(
        window(
          alignment: %{offset_rows: 0.1, band_offset_rows: [0.0, 1.5]},
          row_correction: 6.0,
          sharpness: %{left: 0.0052, right: 0.0032}
        )
      )

    assert PairCheck.camera_issues(checks) == %{
             left: [],
             right: [:large_row_correction, :rotation_mismatch, :focus_mismatch]
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
               :rotation_mismatch,
               :focus_mismatch,
               :brightness_mismatch
             ]
  end
end
