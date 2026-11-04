defmodule VisionCore.Calibration.ChessboardTest do
  use ExUnit.Case, async: false

  alias VisionCore.Calibration.{Board, Chessboard}
  alias VisionCore.Camera.Frame
  alias VisionCore.ChessboardImage

  @board %Board{columns: 8, rows: 6, square_m: 0.025}

  defp frame(image, fields \\ []) do
    struct!(
      Frame,
      [label: "left", width: image.width, height: image.height, capture_ns: 0, grey: image.grey] ++
        fields
    )
  end

  defp assert_corners(corners, expected, tolerance) do
    assert length(corners) == length(expected)

    for {{x, y}, {ex, ey}} <- Enum.zip(corners, expected) do
      assert abs(x - ex) < tolerance and abs(y - ey) < tolerance,
             "corner #{inspect({x, y})} is not within #{tolerance} px of #{inspect({ex, ey})}"
    end
  end

  test "finds the corners of a rendered board within 0.3 px" do
    image = ChessboardImage.render(@board)

    assert {:ok, corners} = Chessboard.detect(frame(image), @board)
    assert length(corners) == 48
    assert_corners(corners, image.corners, 0.3)
  end

  test "orders an upside-down board like an upright one" do
    image = ChessboardImage.render(@board, rotate: true)

    assert {:ok, corners} = Chessboard.detect(frame(image), @board)
    assert_corners(corners, Enum.reverse(image.corners), 0.3)

    {_, first_y} = hd(corners)
    {_, last_y} = List.last(corners)
    assert first_y < last_y
  end

  test "orders a board whose rotation changes its colour pattern like an upright one" do
    board = %Board{columns: 7, rows: 6, square_m: 0.025}
    image = ChessboardImage.render(board, rotate: true)

    assert {:ok, corners} = Chessboard.detect(frame(image), board)
    assert_corners(corners, Enum.reverse(image.corners), 0.3)
  end

  test "finds a board seen in perspective" do
    warp = [[0.95, 0.12, 40.0], [-0.05, 0.9, 30.0], [0.0001, 0.00005, 1.0]]
    image = ChessboardImage.render(@board, warp: warp)

    assert {:ok, corners} = Chessboard.detect(frame(image), @board)
    assert_corners(corners, image.corners, 0.5)
  end

  test "finds nothing in a blank frame" do
    image = %{grey: :binary.copy(<<128>>, 1280 * 720), width: 1280, height: 720}

    assert Chessboard.detect(frame(image), @board) == :not_found
  end

  test "finds nothing in a board cropped by the frame edge" do
    image = ChessboardImage.render(@board, width: 585)

    assert Chessboard.detect(frame(image), @board) == :not_found
  end

  test "accepts corners 8 px from the border and refuses closer ones" do
    assert Chessboard.clear_of_border?([{8.0, 8.0}, {632.0, 472.0}], 640, 480)
    refute Chessboard.clear_of_border?([{7.9, 100.0}], 640, 480)
    refute Chessboard.clear_of_border?([{100.0, 7.9}], 640, 480)
    refute Chessboard.clear_of_border?([{632.1, 100.0}], 640, 480)
    refute Chessboard.clear_of_border?([{100.0, 472.1}], 640, 480)
  end

  test "finds the board in a JPEG frame" do
    start_supervised!(VisionCore.Jpeg)
    image = ChessboardImage.render(@board)

    {:ok, jpeg} = VisionCore.Jpeg.encode(image.grey, image.width, image.height, 1)

    jpeg_frame = %Frame{
      label: "left",
      width: image.width,
      height: image.height,
      capture_ns: 0,
      jpeg: jpeg
    }

    assert {:ok, corners} = Chessboard.detect(jpeg_frame, @board)
    assert_corners(corners, image.corners, 1.0)
  end

  test "reports an undecodable JPEG frame as an error" do
    start_supervised!(VisionCore.Jpeg)
    frame = %Frame{label: "left", width: 8, height: 8, capture_ns: 0, jpeg: <<0, 1, 2>>}

    assert {:error, {:jpeg, _}} = Chessboard.detect(frame, @board)
  end
end
