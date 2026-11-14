defmodule VisionCore.Calibration.SolverTest do
  use ExUnit.Case, async: true

  alias VisionCore.Calibration.{Board, Solver}
  alias VisionCore.Ros2.CameraCalibration

  @width 1280
  @height 720
  @left_intrinsics {900.0, 900.0, 640.0, 360.0}
  @right_intrinsics {910.0, 910.0, 630.0, 365.0}
  @baseline 0.06

  setup_all do
    {:ok, board} = Board.new(8, 6, 0.025)
    {:ok, board: board, samples: synthetic_samples(board, 25)}
  end

  test "recovers the baseline and rectified focal length of a synthetic rig", %{
    board: board,
    samples: samples
  } do
    assert {:ok, result} = Solver.solve(board, {@width, @height}, samples)

    assert result.fx_px == hd(result.left.projection_matrix)
    assert result.fx_px > 900.0 and result.fx_px < 1000.0
    assert_in_delta result.baseline_m, @baseline, @baseline * 0.01
    assert result.left_rms_px < 0.1
    assert result.right_rms_px < 0.1
    assert result.stereo_rms_px < 0.1
    assert result.samples == 25
  end

  test "fills both calibrations", %{board: board, samples: samples} do
    {:ok, result} = Solver.solve(board, {@width, @height}, samples)

    for side <- [result.left, result.right] do
      assert side.width == @width
      assert side.height == @height
      assert side.distortion_model == "plumb_bob"
      assert length(side.distortion_coefficients) == 5
      assert Enum.at(side.distortion_coefficients, 4) == 0.0
      assert length(side.camera_matrix) == 9
      assert length(side.rectification_matrix) == 9
      assert length(side.projection_matrix) == 12
    end

    assert_in_delta Enum.at(result.right.projection_matrix, 3),
                    -result.fx_px * @baseline,
                    result.fx_px * @baseline * 0.005

    assert_in_delta Enum.at(result.left.projection_matrix, 3), 0.0, 1.0e-9
  end

  test "solves one camera alone: its intrinsics, an identity rectification and its own projection",
       %{board: board, samples: samples} do
    views = Enum.map(samples, & &1.left)

    assert {:ok, result} = Solver.solve_camera(board, {@width, @height}, views)

    {fx, fy, cx, cy} = @left_intrinsics
    [k_fx, _, k_cx, _, k_fy, k_cy | _] = result.camera.camera_matrix
    assert_in_delta k_fx, fx, fx * 0.01
    assert_in_delta k_fy, fy, fy * 0.01
    assert_in_delta k_cx, cx, 5.0
    assert_in_delta k_cy, cy, 5.0

    assert result.camera.width == @width
    assert result.camera.height == @height
    assert result.camera.distortion_model == "plumb_bob"
    assert Enum.at(result.camera.distortion_coefficients, 4) == 0.0
    assert result.camera.rectification_matrix == [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    assert length(result.camera.projection_matrix) == 12
    assert Enum.at(result.camera.projection_matrix, 3) == 0.0
    assert result.fx_px == hd(result.camera.projection_matrix)
    assert result.rms_px < 0.1
    assert result.samples == 25
  end

  test "refuses to solve one camera from too few samples", %{board: board, samples: samples} do
    views = samples |> Enum.take(2) |> Enum.map(& &1.left)
    assert {:error, message} = Solver.solve_camera(board, {@width, @height}, views)
    assert message =~ "at least 3 samples"
  end

  test "keeps each camera's own intrinsics and rotation", %{board: board, samples: samples} do
    {:ok, result} = Solver.solve(board, {@width, @height}, samples)

    for {side, {fx, fy, cx, cy}} <- [
          {result.left, @left_intrinsics},
          {result.right, @right_intrinsics}
        ] do
      [sfx, _, scx, _, sfy, scy | _] = side.camera_matrix
      assert_in_delta sfx, fx, fx * 0.005
      assert_in_delta sfy, fy, fy * 0.005
      assert_in_delta scx, cx, cx * 0.005
      assert_in_delta scy, cy, cy * 0.005
    end

    refute result.left.rectification_matrix == result.right.rectification_matrix
  end

  test "the calibrations survive a YAML round trip", %{board: board, samples: samples} do
    {:ok, result} = Solver.solve(board, {@width, @height}, samples)

    for side <- [result.left, result.right] do
      {:ok, parsed} = side |> CameraCalibration.to_yaml("camera") |> CameraCalibration.parse()
      assert parsed.width == side.width
      assert parsed.projection_matrix == side.projection_matrix
      assert parsed.camera_matrix == side.camera_matrix
    end
  end

  test "refuses fewer than 3 samples", %{board: board, samples: samples} do
    assert {:error, message} = Solver.solve(board, {@width, @height}, Enum.take(samples, 2))
    assert is_binary(message)
  end

  test "reports an OpenCV failure as an error", %{board: board} do
    bad = for _ <- 1..3, do: %{left: [{1.0, 1.0}], right: [{1.0, 1.0}]}
    assert {:error, message} = Solver.solve(board, {@width, @height}, bad)
    assert is_binary(message)
  end

  defp synthetic_samples(board, count) do
    :rand.seed(:exsss, {1, 2, 3})
    object = board |> Board.object_points() |> Enum.map(&Tuple.to_list/1)
    object_mat = object |> Nx.tensor(type: :f32) |> Evision.Mat.from_nx()
    left_k = intrinsics(@left_intrinsics)
    right_k = intrinsics(@right_intrinsics)
    d = Evision.Mat.from_nx(Nx.tensor([[0.0, 0.0, 0.0, 0.0, 0.0]], type: :f64))

    Stream.repeatedly(fn -> random_pose() end)
    |> Stream.map(fn {rvec, tvec} ->
      left = project(object_mat, rvec, tvec, left_k, d)
      {right_rvec, right_tvec} = right_pose(rvec, tvec)
      right = project(object_mat, right_rvec, right_tvec, right_k, d)
      %{left: left, right: right}
    end)
    |> Stream.filter(fn %{left: left, right: right} ->
      Enum.all?(left ++ right, fn {x, y} ->
        x > 20 and x < @width - 20 and y > 20 and y < @height - 20
      end)
    end)
    |> Enum.take(count)
  end

  defp random_pose() do
    z = 0.5 + :rand.uniform()
    tilt = :math.pi() / 6
    angle = :rand.uniform() * tilt
    direction = :rand.uniform() * 2 * :math.pi()

    rvec =
      Nx.tensor(
        [
          angle * :math.cos(direction),
          angle * :math.sin(direction),
          (:rand.uniform() - 0.5) * 0.4
        ],
        type: :f64
      )

    x = (:rand.uniform() - 0.5) * 0.5 * z
    y = (:rand.uniform() - 0.5) * 0.3 * z
    {rvec, Nx.tensor([x, y, z], type: :f64)}
  end

  defp right_pose(rvec, tvec) do
    {rvec_rel, tvec_rel} =
      {Nx.tensor([0.0, 0.035, 0.0], type: :f64), Nx.tensor([-@baseline, 0.0, 0.0], type: :f64)}

    {right_rvec, right_tvec, _, _, _, _, _, _, _, _} =
      Evision.composeRT(
        Evision.Mat.from_nx(rvec),
        Evision.Mat.from_nx(tvec),
        Evision.Mat.from_nx(rvec_rel),
        Evision.Mat.from_nx(tvec_rel)
      )

    {Evision.Mat.to_nx(right_rvec, Nx.BinaryBackend),
     Evision.Mat.to_nx(right_tvec, Nx.BinaryBackend)}
  end

  defp intrinsics({fx, fy, cx, cy}) do
    Evision.Mat.from_nx(Nx.tensor([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], type: :f64))
  end

  defp project(object_mat, rvec, tvec, k, d) do
    {points, _jacobian} =
      Evision.projectPoints(
        object_mat,
        Evision.Mat.from_nx(rvec),
        Evision.Mat.from_nx(tvec),
        k,
        d
      )

    points
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.reshape({:auto, 2})
    |> Nx.to_list()
    |> Enum.map(&List.to_tuple/1)
  end

  describe "solve_pose/3" do
    # Inner corners odd by even: the board reads differently after a half turn.
    @pose_board_size {9, 6, 0.04}
    @pose_frame_size {1014, 760}
    @left_lens %{
      k: [700.0, 0.0, 500.0, 0.0, 702.0, 380.0, 0.0, 0.0, 1.0],
      d: [-0.12, 0.04, 0.001, -0.0005, -0.006]
    }
    @camera_lens %{
      k: [880.0, 0.0, 510.0, 0.0, 878.0, 372.0, 0.0, 0.0, 1.0],
      d: [-0.2, 0.08, -0.0008, 0.0012, -0.01]
    }
    # The left calibration's rectification, raw left frame to rectified, as a Rodrigues vector.
    @rectification [0.01, -0.02, 0.015]
    # The pose to recover, from the rectified left frame: the camera 12 cm right, 3 cm down, turned.
    @pose_rotation [0.03, -0.08, 0.05]
    @pose_translation [-0.12, 0.03, 0.01]
    # Each board pose seen: tilts and turn in radians, then the board centre in metres from the left camera.
    @board_poses [
      {0.0, 0.0, 0.0, 0.0, 0.0, 1.0},
      {0.4, 0.0, 0.1, -0.2, 0.0, 1.2},
      {-0.4, 0.2, -0.1, 0.2, 0.1, 1.1},
      {0.1, 0.5, 0.2, 0.1, -0.15, 0.9},
      {0.0, -0.5, 0.0, -0.1, 0.15, 1.4},
      {0.3, 0.3, 0.3, 0.25, -0.1, 1.3},
      {-0.3, -0.3, -0.2, -0.25, 0.1, 1.0},
      {0.2, -0.2, 0.0, 0.0, 0.2, 0.8}
    ]

    setup do
      {columns, rows, square_m} = @pose_board_size
      {:ok, board} = Board.new(columns, rows, square_m)
      %{board: board}
    end

    test "recovers the pose from the rectified left frame to the camera, in metres",
         %{board: board} do
      rotation = rotation_matrix(@pose_rotation)
      cameras = pose_cameras(lens_calibration(@camera_lens, @pose_frame_size))

      assert {:ok, result} =
               Solver.solve_pose(board, cameras, pose_samples(board, rotation))

      assert result.rms_px < 1.0e-3
      assert_all_in_delta(result.pose.rotation, Nx.to_flat_list(rotation), 1.0e-6)
      assert_all_in_delta(result.pose.translation, @pose_translation, 1.0e-6)
      assert_in_delta result.distance_m, norm(@pose_translation), 1.0e-6
      assert result.samples == length(@board_poses)
    end

    test "scales each calibration to its camera's frames, pixel centres onto pixel centres",
         %{board: board} do
      rotation = rotation_matrix(@pose_rotation)
      {width, height} = @pose_frame_size
      # Twice the size, pixel centres on pixel centres: u becomes (u + 1/2) * 2 - 1/2.
      [fx, _, cx, _, fy, cy | _] = @camera_lens.k

      full_size = %{
        @camera_lens
        | k: [2 * fx, 0.0, 2 * cx + 0.5, 0.0, 2 * fy, 2 * cy + 0.5, 0.0, 0.0, 1.0]
      }

      cameras = pose_cameras(lens_calibration(full_size, {2 * width, 2 * height}))

      assert {:ok, result} = Solver.solve_pose(board, cameras, pose_samples(board, rotation))

      assert_all_in_delta(result.pose.rotation, Nx.to_flat_list(rotation), 1.0e-6)
      assert_all_in_delta(result.pose.translation, @pose_translation, 1.0e-6)
    end

    test "recovers a camera turned upside down", %{board: board} do
      upside_down = rotation_matrix([0.0, 0.0, :math.pi() - 0.05])
      cameras = pose_cameras(lens_calibration(@camera_lens, @pose_frame_size))

      assert {:ok, result} = Solver.solve_pose(board, cameras, pose_samples(board, upside_down))

      assert_all_in_delta(result.pose.rotation, Nx.to_flat_list(upside_down), 1.0e-6)
      assert_all_in_delta(result.pose.translation, @pose_translation, 1.0e-6)
    end

    test "refuses a calibration of another aspect ratio than its camera's frames",
         %{board: board} do
      {width, height} = @pose_frame_size
      cameras = pose_cameras(lens_calibration(@camera_lens, {2 * width, height}))
      samples = pose_samples(board, rotation_matrix(@pose_rotation))

      assert {:error, message} = Solver.solve_pose(board, cameras, samples)
      assert message =~ "#{2 * width}x#{height}"
      assert message =~ "#{width}x#{height}"
    end

    test "refuses a distortion model other than plumb_bob, naming it", %{board: board} do
      fisheye = %{
        lens_calibration(@camera_lens, @pose_frame_size)
        | distortion_model: "equidistant",
          distortion_coefficients: [0.05, -0.02, 0.006, -0.002]
      }

      samples = pose_samples(board, rotation_matrix(@pose_rotation))

      assert {:error, message} = Solver.solve_pose(board, pose_cameras(fisheye), samples)
      assert message =~ "equidistant"
    end

    test "refuses fewer than 3 samples", %{board: board} do
      cameras = pose_cameras(lens_calibration(@camera_lens, @pose_frame_size))
      samples = board |> pose_samples(rotation_matrix(@pose_rotation)) |> Enum.take(2)

      assert {:error, message} = Solver.solve_pose(board, cameras, samples)
      assert message =~ "at least 3 samples"
    end
  end

  defp pose_cameras(camera_calibration) do
    left = %{
      lens_calibration(@left_lens, @pose_frame_size)
      | rectification_matrix: Nx.to_flat_list(rotation_matrix(@rectification))
    }

    %{
      left: %{calibration: left, size: @pose_frame_size},
      camera: %{calibration: camera_calibration, size: @pose_frame_size}
    }
  end

  defp lens_calibration(%{k: k, d: d}, {width, height}) do
    [fx, _, cx, _, fy, cy | _] = k

    %CameraCalibration{
      width: width,
      height: height,
      distortion_model: "plumb_bob",
      distortion_coefficients: d,
      camera_matrix: k,
      rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      projection_matrix: [fx, 0.0, cx, 0.0, 0.0, fy, cy, 0.0, 0.0, 0.0, 1.0, 0.0]
    }
  end

  # The board corners each camera sees, the camera at `rotation` and the translation from the rectified left frame.
  defp pose_samples(board, rotation) do
    raw_rotation = Nx.dot(rotation, rotation_matrix(@rectification))
    translation = Nx.tensor(@pose_translation, type: :f64)
    object = board |> Board.object_points() |> Enum.map(&Tuple.to_list/1)
    object_mat = object |> Nx.tensor(type: :f64) |> Evision.Mat.from_nx()

    centre =
      Nx.tensor(
        [(board.columns - 1) * board.square_m / 2, (board.rows - 1) * board.square_m / 2, 0.0],
        type: :f64
      )

    for {tilt_x, tilt_y, turn, x, y, distance} <- @board_poses do
      board_rotation = rotation_matrix([tilt_x, tilt_y, turn])

      board_translation =
        Nx.subtract(Nx.tensor([x, y, distance], type: :f64), Nx.dot(board_rotation, centre))

      camera_rotation = Nx.dot(raw_rotation, board_rotation)
      camera_translation = Nx.add(Nx.dot(raw_rotation, board_translation), translation)

      %{
        left: project_lens(object_mat, board_rotation, board_translation, @left_lens),
        camera: project_lens(object_mat, camera_rotation, camera_translation, @camera_lens)
      }
    end
  end

  defp project_lens(object_mat, rotation, translation, %{k: k, d: d}) do
    {rvec, _jacobian} = Evision.rodrigues(Evision.Mat.from_nx(rotation))
    camera_matrix = Evision.Mat.from_nx(Nx.tensor(k, type: :f64) |> Nx.reshape({3, 3}))
    distortion = Evision.Mat.from_nx(Nx.tensor([d], type: :f64))

    project(
      object_mat,
      Evision.Mat.to_nx(rvec, Nx.BinaryBackend),
      translation,
      camera_matrix,
      distortion
    )
  end

  defp rotation_matrix(rodrigues) do
    {matrix, _jacobian} = Evision.rodrigues(Evision.Mat.from_nx(Nx.tensor(rodrigues, type: :f64)))
    Evision.Mat.to_nx(matrix, Nx.BinaryBackend)
  end

  defp norm(vector), do: :math.sqrt(Enum.sum(Enum.map(vector, &(&1 * &1))))

  defp assert_all_in_delta(actual, expected, delta) do
    assert length(actual) == length(expected)

    for {actual_value, expected_value} <- Enum.zip(actual, expected),
        do: assert_in_delta(actual_value, expected_value, delta)
  end
end
