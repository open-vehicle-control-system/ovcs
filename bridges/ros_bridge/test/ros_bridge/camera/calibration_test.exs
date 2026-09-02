defmodule RosBridge.Camera.CalibrationTest do
  use ExUnit.Case, async: true

  alias RosBridge.Camera.Calibration

  # Verbatim shape of what ROS `cameracalibrator` writes on SAVE:
  # whole numbers carry a bare trailing dot and the flow sequence
  # spans several lines. Parsing this used to raise inside
  # `Stereo.OpenCV.init/1` and take the bridge down at boot.
  @ost_style """
  image_width: 640
  image_height: 480
  camera_name: narrow_stereo/left
  camera_matrix:
    rows: 3
    cols: 3
    data: [725.11023,   0.     , 314.60834,
             0.     , 967.13528, 237.88589,
             0.     ,   0.     ,   1.     ]
  distortion_model: plumb_bob
  distortion_coefficients:
    rows: 1
    cols: 5
    data: [0.005562, 0.191870, -0.003399, -0.001653, 0.000000]
  rectification_matrix:
    rows: 3
    cols: 3
    data: [ 0.99606354,  0.00368581,  0.08856544,
           -0.00449872,  0.99994955,  0.00898079,
           -0.08852787, -0.00934386,  0.99602987]
  projection_matrix:
    rows: 3
    cols: 4
    data: [1046.54251,    0.     ,  203.28751,    0.     ,
              0.     , 1046.54251,  232.82874,    0.     ,
              0.     ,    0.     ,    1.     ,    0.     ]
  """

  test "parses cameracalibrator output, including bare trailing-dot floats" do
    calibration = Calibration.parse(@ost_style)

    assert calibration.width == 640
    assert calibration.height == 480

    # The entries that used to raise: "0." and "1.".
    assert [725.11023, 0.0, 314.60834 | _] = calibration.camera_matrix
    assert Enum.at(calibration.camera_matrix, 8) == 1.0
    assert Enum.all?(calibration.camera_matrix, &is_float/1)

    # Baseline lives in P[0,3] of the right camera; here it is 0.0
    # for the left, and must still be a float rather than a string.
    assert Enum.at(calibration.projection_matrix, 3) == 0.0
    assert Enum.all?(calibration.projection_matrix, &is_float/1)
    assert Enum.all?(calibration.rectification_matrix, &is_float/1)
    assert Enum.all?(calibration.distortion_coefficients, &is_float/1)
  end

  test "accepts leading-dot and integer spellings too" do
    body = """
    camera_matrix:
      rows: 3
      cols: 3
      data: [.5, -.25, 3, 0., -0., 1e-3, 2.5E2, 0.0, 1]
    """

    assert Calibration.parse(body).camera_matrix ==
             [0.5, -0.25, 3.0, 0.0, -0.0, 1.0e-3, 250.0, 0.0, 1.0]
  end

  describe "scale_to/3" do
    setup do
      %{cal: Calibration.parse(@ost_style)}
    end

    test "scales pixel-indexed intrinsics and leaves the rest alone", %{cal: cal} do
      # 640x360 -> 480x270 is the proportional resize the vehicle uses.
      scaled = Calibration.scale_to(%{cal | width: 640, height: 360}, 480, 270)

      assert scaled.width == 480
      assert scaled.height == 270

      [fx, _, cx | _] = scaled.camera_matrix
      [ofx, _, ocx | _] = cal.camera_matrix
      assert_in_delta fx, ofx * 0.75, 1.0e-6
      assert_in_delta cx, ocx * 0.75, 1.0e-6

      # D and R carry no pixel units.
      assert scaled.distortion_coefficients == cal.distortion_coefficients
      assert scaled.rectification_matrix == cal.rectification_matrix
    end

    test "preserves the baseline encoded in P[0,3] = -fx x T", %{cal: cal} do
      right = %{cal | width: 640, height: 360, projection_matrix: [800.0, 0.0, 320.0, -72.0, 0.0, 800.0, 180.0, 0.0, 0.0, 0.0, 1.0, 0.0]}
      scaled = Calibration.scale_to(right, 480, 270)

      baseline = fn c ->
        [fx, _, _, tx | _] = c.projection_matrix
        -tx / fx
      end

      # fx and P[0,3] scale together, so metres come out unchanged —
      # this is what makes reusing a calibration across resolutions
      # legitimate.
      assert_in_delta baseline.(scaled), baseline.(right), 1.0e-9
    end

    test "is a no-op at the same resolution", %{cal: cal} do
      sized = %{cal | width: 640, height: 360}
      assert Calibration.scale_to(sized, 640, 360) == sized
    end
  end
end
