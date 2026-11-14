defmodule VisionCore.Ros2.CameraCalibrationTest do
  use ExUnit.Case, async: true

  alias VisionCore.Ros2.CameraCalibration

  @fixtures Path.expand("../../support/calibration", __DIR__)

  # Verbatim shape of what ROS `cameracalibrator` writes on SAVE:
  # whole numbers carry a bare trailing dot and the flow sequence
  # spans several lines.
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
    assert {:ok, calibration} = CameraCalibration.parse(@ost_style)

    assert calibration.width == 640
    assert calibration.height == 480

    # The bare trailing-dot entries: "0." and "1.".
    assert [725.11023, +0.0, 314.60834 | _] = calibration.camera_matrix
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
    calibration_yaml =
      String.replace(
        @ost_style,
        ~r/camera_matrix:.*?\]/s,
        "camera_matrix:\n  data: [.5, -.25, 3, 0., 1e-3, -0., 2.5E2, 0.0, 1]"
      )

    assert {:ok, calibration} = CameraCalibration.parse(calibration_yaml)
    assert calibration.camera_matrix == [0.5, -0.25, 3.0, 0.0, 1.0e-3, -0.0, 250.0, 0.0, 1.0]
  end

  describe "parse/1 of a file that is no calibration" do
    test "says an empty file has no camera matrix" do
      assert CameraCalibration.parse("") ==
               {:error, "its camera matrix has 0 values, not 9"}
    end

    test "says which matrix a file cut short lacks" do
      {cut, _rest} = :binary.split(@ost_style, "projection_matrix:") |> List.to_tuple()

      assert CameraCalibration.parse(cut) ==
               {:error, "its projection matrix has 0 values, not 12"}
    end

    test "refuses a matrix whose closing bracket was lost before the next block" do
      broken = String.replace(@ost_style, "0.     ,   0.     ,   1.     ]", "0.     ,   0.")

      assert {:error, message} = CameraCalibration.parse(broken)
      assert message =~ "is no number"
    end

    test "refuses a value that is not a finite number" do
      for spelling <- [".nan", ".inf", "-.inf", "NaN", "abc"] do
        yaml = String.replace(@ost_style, "725.11023", spelling)

        assert CameraCalibration.parse(yaml) ==
                 {:error, "#{inspect(spelling)} is no number"}
      end
    end

    test "refuses a file whose focal lengths are zero" do
      zeroed = String.replace(@ost_style, "725.11023", "0.")

      assert CameraCalibration.parse(zeroed) == {:error, "its focal lengths are not positive"}
    end
  end

  describe "load/1" do
    @describetag :tmp_dir

    test "answers why a file is no calibration, and load!/1 raises it", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "cut.yaml")
      File.write!(path, "image_width: 640\ncamera_matrix:\n  data: [1, 2")

      assert CameraCalibration.load(path) ==
               {:error, {:malformed, "its camera matrix has 0 values, not 9"}}

      assert_raise RuntimeError, ~r/its camera matrix has 0 values, not 9/, fn ->
        CameraCalibration.load!(path)
      end
    end

    test "answers the file error of a file it cannot read", %{tmp_dir: tmp_dir} do
      assert CameraCalibration.load(Path.join(tmp_dir, "none.yaml")) == {:error, :enoent}
    end
  end

  describe "scale_to/3" do
    setup do
      {:ok, calibration} = CameraCalibration.parse(@ost_style)
      %{calibration: calibration}
    end

    test "scales pixel-indexed intrinsics and leaves the rest alone", %{calibration: calibration} do
      # 640x360 -> 480x270, a proportional resize.
      scaled = CameraCalibration.scale_to(%{calibration | width: 640, height: 360}, 480, 270)

      assert scaled.width == 480
      assert scaled.height == 270

      [fx, _, cx | _] = scaled.camera_matrix
      [original_fx, _, original_cx | _] = calibration.camera_matrix
      assert_in_delta fx, original_fx * 0.75, 1.0e-6
      assert_in_delta cx, original_cx * 0.75, 1.0e-6

      # D and R carry no pixel units.
      assert scaled.distortion_coefficients == calibration.distortion_coefficients
      assert scaled.rectification_matrix == calibration.rectification_matrix
    end

    test "preserves the baseline encoded in P[0,3] = -fx x T", %{calibration: calibration} do
      right = %{
        calibration
        | width: 640,
          height: 360,
          projection_matrix: [
            800.0,
            0.0,
            320.0,
            -72.0,
            0.0,
            800.0,
            180.0,
            0.0,
            0.0,
            0.0,
            1.0,
            0.0
          ]
      }

      scaled = CameraCalibration.scale_to(right, 480, 270)

      baseline = fn calibration ->
        [fx, _, _, tx | _] = calibration.projection_matrix
        -tx / fx
      end

      # fx and P[0,3] scale together, so metres come out unchanged —
      # this is what makes reusing a calibration across resolutions
      # legitimate.
      assert_in_delta baseline.(scaled), baseline.(right), 1.0e-9
    end

    test "is a no-op at the same resolution", %{calibration: calibration} do
      sized = %{calibration | width: 640, height: 360}
      assert CameraCalibration.scale_to(sized, 640, 360) == sized
    end
  end

  describe "resample_to/3" do
    setup do
      {:ok, parsed} = CameraCalibration.parse(@ost_style)

      calibration = %{
        parsed
        | width: 2028,
          height: 1520,
          camera_matrix: [1161.3, 0.0, 1013.5, 0.0, 1161.3, 759.5, 0.0, 0.0, 1.0],
          projection_matrix: [
            1161.3,
            0.0,
            1013.5,
            -72.0,
            0.0,
            1161.3,
            759.5,
            0.0,
            0.0,
            0.0,
            1.0,
            0.0
          ]
      }

      %{calibration: calibration}
    end

    test "maps pixel centres for a 2x2 block average: f / 2, (c + 1/2) / 2 - 1/2",
         %{calibration: calibration} do
      averaged = CameraCalibration.resample_to(calibration, 1014, 760)

      assert {averaged.width, averaged.height} == {1014, 760}
      [fx, skew, cx, _, fy, cy, _, _, _] = averaged.camera_matrix
      assert_in_delta fx, 580.65, 1.0e-9
      assert_in_delta fy, 580.65, 1.0e-9
      assert skew == 0.0
      assert_in_delta cx, 506.5, 1.0e-9
      assert_in_delta cy, 379.5, 1.0e-9

      [pfx, _, pcx, ptx, _, pfy, pcy, pty | _] = averaged.projection_matrix
      assert_in_delta pfx, 580.65, 1.0e-9
      assert_in_delta pcx, 506.5, 1.0e-9
      assert_in_delta ptx, -36.0, 1.0e-9
      assert_in_delta pfy, 580.65, 1.0e-9
      assert_in_delta pcy, 379.5, 1.0e-9
      assert pty == 0.0
      assert averaged.distortion_coefficients == calibration.distortion_coefficients
      assert averaged.rectification_matrix == calibration.rectification_matrix
    end

    test "maps a centre back where it was", %{calibration: calibration} do
      back =
        calibration
        |> CameraCalibration.resample_to(507, 380)
        |> CameraCalibration.resample_to(2028, 1520)

      for {value, original} <- Enum.zip(back.camera_matrix, calibration.camera_matrix),
          do: assert_in_delta(value, original, 1.0e-9)
    end

    test "is a no-op at the same resolution, and takes a calibration without a size as it is",
         %{calibration: calibration} do
      assert CameraCalibration.resample_to(calibration, 2028, 1520) == calibration

      sizeless = %{calibration | width: 0, height: 0}

      assert CameraCalibration.resample_to(sizeless, 1014, 760) ==
               %{sizeless | width: 1014, height: 760}
    end
  end

  describe "proportional?/3" do
    setup do
      {:ok, calibration} = CameraCalibration.parse(@ost_style)
      %{calibration: %{calibration | width: 4056, height: 3040}}
    end

    test "is true for a resize that keeps the aspect ratio within 1 %", %{
      calibration: calibration
    } do
      assert CameraCalibration.proportional?(calibration, 2028, 1520)
      assert CameraCalibration.proportional?(calibration, 1014, 760)
      assert CameraCalibration.proportional?(%{calibration | width: 0, height: 0}, 2028, 1080)
    end

    test "is false for a size of another aspect ratio, as a cropping sensor mode gives", %{
      calibration: calibration
    } do
      refute CameraCalibration.proportional?(calibration, 2028, 1080)
      refute CameraCalibration.proportional?(calibration, 4056, 2980)
    end
  end

  describe "check/1" do
    setup do
      {:ok, calibration} = CameraCalibration.load(Path.join(@fixtures, "distorted_left.yaml"))
      %{calibration: calibration}
    end

    test "takes a calibration with its matrices, focal lengths and distortion coefficients", %{
      calibration: calibration
    } do
      assert CameraCalibration.check(calibration) == :ok
    end

    test "names the matrix that has another count", %{calibration: calibration} do
      for {field, name, count} <- [
            {:camera_matrix, "camera", 9},
            {:rectification_matrix, "rectification", 9},
            {:projection_matrix, "projection", 12}
          ] do
        short = Map.put(calibration, field, [1.0, 2.0])

        assert CameraCalibration.check(short) ==
                 {:error, "its #{name} matrix has 2 values, not #{count}"}
      end
    end

    test "refuses a value that is no number", %{calibration: calibration} do
      matrix = List.replace_at(calibration.camera_matrix, 4, nil)

      assert CameraCalibration.check(%{calibration | camera_matrix: matrix}) ==
               {:error, "its camera matrix holds a value that is no number"}
    end

    test "refuses focal lengths that are not positive", %{calibration: calibration} do
      for index <- [0, 4] do
        matrix = List.replace_at(calibration.camera_matrix, index, 0.0)

        assert CameraCalibration.check(%{calibration | camera_matrix: matrix}) ==
                 {:error, "its focal lengths are not positive"}
      end
    end

    test "refuses a count of distortion coefficients that is not its model's", %{
      calibration: calibration
    } do
      for {model, count} <- [{"plumb_bob", 5}, {"rational_polynomial", 8}, {"equidistant", 4}] do
        fitting = %{
          calibration
          | distortion_model: model,
            distortion_coefficients: List.duplicate(0.0, count)
        }

        assert CameraCalibration.check(fitting) == :ok

        assert CameraCalibration.check(%{fitting | distortion_coefficients: [0.0]}) ==
                 {:error, "it has 1 distortion coefficients, not the #{count} of #{model}"}
      end
    end
  end
end
