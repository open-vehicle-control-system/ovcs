defmodule VisionCore.Camera.VideoQueueTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{Frame, VideoQueue}

  defp frame(capture_ns, keyframe?),
    do: %Frame{
      label: "hq",
      width: 2,
      height: 2,
      capture_ns: capture_ns,
      h264: <<capture_ns>>,
      keyframe?: keyframe?
    }

  defp key(capture_ns), do: frame(capture_ns, true)
  defp delta(capture_ns), do: frame(capture_ns, false)

  defp push_all(queue, frames), do: Enum.reduce(frames, queue, &VideoQueue.push(&2, &1))

  defp drain(queue) do
    case VideoQueue.pop(queue) do
      {:ok, frame, queue} -> [frame.capture_ns | drain(queue)]
      :empty -> []
    end
  end

  test "hands the frames back in their order" do
    queue = VideoQueue.new(10) |> push_all([key(1), delta(2), delta(3)])

    assert VideoQueue.size(queue) == 3
    assert drain(queue) == [1, 2, 3]
  end

  test "starts at a key frame, the frames before the first dropped" do
    queue = VideoQueue.new(10) |> push_all([delta(1), delta(2), key(3), delta(4)])

    assert drain(queue) == [3, 4]
  end

  test "a frame past its limit empties it, and it starts again at the next key frame" do
    queue =
      VideoQueue.new(3) |> push_all([key(1), delta(2), delta(3), delta(4), delta(5), key(6)])

    assert drain(queue) == [6]
  end

  test "a key frame past its limit starts it again at once" do
    queue = VideoQueue.new(2) |> push_all([key(1), delta(2), key(3), delta(4)])

    assert drain(queue) == [3, 4]
  end

  test "frames taken out make room, the stream unbroken" do
    queue = VideoQueue.new(2) |> push_all([key(1), delta(2)])
    {:ok, %Frame{capture_ns: 1}, queue} = VideoQueue.pop(queue)
    queue = VideoQueue.push(queue, delta(3))

    assert drain(queue) == [2, 3]
  end
end
