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
      parsed = side |> CameraCalibration.to_yaml("camera") |> CameraCalibration.parse()
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
end
