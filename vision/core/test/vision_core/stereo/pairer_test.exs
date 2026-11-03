defmodule VisionCore.Stereo.PairerTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Pairer

  # Names the cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  defp frame(label, capture_time_ms),
    do: %Frame{
      label: label,
      width: 4,
      height: 4,
      jpeg: <<>>,
      capture_ns: capture_time_ms * 1_000_000
    }

  defp frames(label, capture_times_ms),
    do: capture_times_ms |> Enum.reverse() |> Enum.map(&frame(label, &1))

  defp state(left_capture_times_ms, right_capture_times_ms, tolerance_ms) do
    %{
      left_frames: frames("left", left_capture_times_ms),
      right_frames: frames("right", right_capture_times_ms),
      pair_tolerance_ns: tolerance_ms * 1_000_000
    }
  end

  defp capture_ms({:ok, left, right, _delta}),
    do: {div(left.capture_ns, 1_000_000), div(right.capture_ns, 1_000_000)}

  test "pairs the frames its cameras publish and submits them to its pipeline" do
    start_supervised!({Pairer, cameras: [{Camera, "left"}, {Camera, "right"}], pipeline: self()})

    for label <- ["left", "right"],
        do:
          Outputs.publish(
            {:camera_frame, Camera.name_for(label)},
            {:camera_frame, frame(label, 33)}
          )

    assert_receive {:"$gen_cast",
                    {:submit, %Frame{label: "left"}, %Frame{label: "right"}, _pairer}}
  end

  test "measures the sync of the frames its cameras publish" do
    pairer =
      start_supervised!(
        {Pairer, cameras: [{Camera, "left"}, {Camera, "right"}], pipeline: self(), fps: 30}
      )

    assert Pairer.sync(pairer) == %{offset_median_ms: nil, offset_max_ms: nil, pairs: 0}

    for {label, capture_ns} <- [{"left", 1_000_000_000}, {"right", 1_000_200_000}],
        do:
          Outputs.publish(
            {:camera_frame, Camera.name_for(label)},
            {:camera_frame, %{frame(label, 0) | capture_ns: capture_ns}}
          )

    assert %{pairs: 1, offset_median_ms: offset_ms} = Pairer.sync(pairer)
    assert_in_delta offset_ms, 0.2, 1.0e-9
  end

  test "nothing to pair until both sides have a frame" do
    assert Pairer.ready_pair(state([0], [], 5)) == :not_ready
    assert Pairer.ready_pair(state([], [0], 5)) == :not_ready
  end

  test "pairs the frames taken together, not the newest of each" do
    # Synchronised cameras; the left camera's next frame has already
    # arrived, the right one's not yet.
    assert capture_ms(Pairer.ready_pair(state([33, 66], [33], 5))) == {33, 33}
  end

  test "among equally close pairs, the newest" do
    assert capture_ms(Pairer.ready_pair(state([0, 33, 66], [0, 33, 66], 5))) == {66, 66}
  end

  test "among nearly equally close pairs, the newest" do
    # Synchronised cameras whose frame starts differ by a few microseconds, a different few each time.
    at = fn label, capture_ns -> %{frame(label, 0) | capture_ns: capture_ns} end

    state = %{
      left_frames: Enum.map([66_000_000, 33_000_000, 0], &at.("left", &1)),
      right_frames: Enum.map([66_040_000, 33_010_000, 2_000], &at.("right", &1)),
      pair_tolerance_ns: 5_000_000
    }

    assert capture_ms(Pairer.ready_pair(state)) == {66, 66}
  end

  test "with a steady phase offset, the pairs one offset apart rather than a cycle apart" do
    # The right camera shoots 13 ms before the left one.
    pair = Pairer.ready_pair(state([13, 46], [0, 33, 66], 100))
    assert capture_ms(pair) == {46, 33}
    assert {:ok, _, _, 13_000_000} = pair
  end

  test "reports the closest gap when no pair is within the tolerance" do
    assert Pairer.ready_pair(state([13], [0], 5)) == {:out_of_tolerance, 13_000_000}
  end
end
