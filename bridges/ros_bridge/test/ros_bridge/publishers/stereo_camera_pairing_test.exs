defmodule RosBridge.Publishers.StereoCameraPairingTest do
  use ExUnit.Case, async: true

  alias RosBridge.Camera.Frame
  alias RosBridge.Publishers.StereoCamera

  defp frame(label, ms),
    do: %Frame{label: label, width: 4, height: 4, jpeg: <<>>, capture_ns: ms * 1_000_000}

  defp frames(label, ms_list), do: ms_list |> Enum.reverse() |> Enum.map(&frame(label, &1))

  defp state(lefts, rights, tolerance_ms) do
    %{
      left_frames: frames("left", lefts),
      right_frames: frames("right", rights),
      pair_tolerance_ns: tolerance_ms * 1_000_000
    }
  end

  defp capture_ms({:ok, left, right, _delta}),
    do: {div(left.capture_ns, 1_000_000), div(right.capture_ns, 1_000_000)}

  test "nothing to pair until both sides have a frame" do
    assert StereoCamera.ready_pair(state([0], [], 5)) == :not_ready
    assert StereoCamera.ready_pair(state([], [0], 5)) == :not_ready
  end

  test "pairs the frames taken together, not the newest of each" do
    # Synchronised cameras; the left camera's next frame has already
    # arrived, the right one's not yet.
    assert capture_ms(StereoCamera.ready_pair(state([33, 66], [33], 5))) == {33, 33}
  end

  test "among equally close pairs, the newest" do
    assert capture_ms(StereoCamera.ready_pair(state([0, 33, 66], [0, 33, 66], 5))) == {66, 66}
  end

  test "with a steady phase offset, the pairs one offset apart rather than a cycle apart" do
    # The right camera shoots 13 ms before the left one.
    pair = StereoCamera.ready_pair(state([13, 46], [0, 33, 66], 100))
    assert capture_ms(pair) == {46, 33}
    assert {:ok, _, _, 13_000_000} = pair
  end

  test "reports the closest gap when no pair is within the tolerance" do
    assert StereoCamera.ready_pair(state([13], [0], 5)) == {:out_of_tolerance, 13_000_000}
  end
end
