defmodule VisionCore.Stereo.PairerTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Pairer

  # Names the cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # Labels that are not the sides' names: the pairer tells the sides apart by its :cameras.
  @cameras [left: {Camera, "front/left"}, right: {Camera, "front/right"}]

  defp label(side), do: elem(@cameras[side], 1)

  defp publish_frame(side, frame),
    do: Outputs.publish({:camera_frame, Camera.name_for(label(side))}, {:camera_frame, frame})

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
    pairer =
      start_supervised!({Pairer, cameras: @cameras, pipeline: self()})

    for side <- [:left, :right], do: publish_frame(side, frame(label(side), 33))

    # A barrier: the Pairer handles both frames, and submits, before it answers.
    Pairer.sync(pairer)

    assert_received {:"$gen_cast",
                     {:submit, %Frame{label: "front/left"}, %Frame{label: "front/right"}, _pairer}}
  end

  test "its tolerance changes while it runs, from the next pair on" do
    pairer =
      start_supervised!({Pairer, cameras: @cameras, pipeline: self(), pair_tolerance_ms: 5})

    publish = fn side, capture_ms -> publish_frame(side, frame(label(side), capture_ms)) end

    assert Pairer.pair_tolerance_ms(pairer) == 5
    publish.(:left, 100)
    publish.(:right, 120)
    Pairer.sync(pairer)
    refute_received {:"$gen_cast", {:submit, _left, _right, _pairer}}

    assert Pairer.put_pair_tolerance_ms(pairer, 25) == :ok
    publish.(:right, 121)
    Pairer.sync(pairer)

    assert_received {:"$gen_cast", {:submit, %Frame{label: "front/left"}, %Frame{}, _pairer}}
    assert Pairer.pair_tolerance_ms(pairer) == 25
  end

  test "refuses a tolerance that is no integer from 0 to 1000 ms, at start and while it runs" do
    Process.flag(:trap_exit, true)
    cameras = @cameras

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             Pairer.start_link(cameras: cameras, pipeline: self(), pair_tolerance_ms: -1)

    assert message == "its :pair_tolerance_ms must be from 0 to 1000, got -1"

    pairer = start_supervised!({Pairer, cameras: cameras, pipeline: self()})

    assert Pairer.put_pair_tolerance_ms(pairer, 1.5) ==
             {:error, "pair_tolerance_ms must be an integer, got 1.5"}
  end

  test "refuses at start an :fps that is no integer from 1 on" do
    for fps <- [0, 29.97, nil] do
      assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
               start_supervised({Pairer, cameras: @cameras, pipeline: self(), fps: fps})

      assert message =~ ":fps"
    end
  end

  test "measures the sync of the frames its cameras publish" do
    pairer =
      start_supervised!({Pairer, cameras: @cameras, pipeline: self(), fps: 30})

    assert Pairer.sync(pairer) == %{offset_median_ms: nil, offset_max_ms: nil, pairs: 0}

    for {side, capture_ns} <- [left: 1_000_000_000, right: 1_000_200_000],
        do: publish_frame(side, %{frame(label(side), 0) | capture_ns: capture_ns})

    assert %{pairs: 1, offset_median_ms: offset_ms} = Pairer.sync(pairer)
    assert_in_delta offset_ms, 0.2, 1.0e-9
  end

  describe "latencies/1" do
    # A clock the test sets, read by the pairer in place of the monotonic one.
    defp start_clock(now_ms) do
      clock = start_supervised!({Agent, fn -> now_ms * 1_000_000 end})
      {clock, fn -> Agent.get(clock, & &1) end}
    end

    defp set_clock(clock, now_ms), do: Agent.update(clock, fn _now_ns -> now_ms * 1_000_000 end)

    defp start_timed_pairer(now_ns) do
      start_supervised!({Pairer, cameras: @cameras, pipeline: self(), now_ns: now_ns})
    end

    defp publish(side, capture_time_ms),
      do: publish_frame(side, frame(label(side), capture_time_ms))

    test "measures each frame from its capture to its arrival, and each pair's wait to be submitted" do
      {clock, now_ns} = start_clock(1_000)
      pairer = start_timed_pairer(now_ns)

      publish(:left, 996)
      Pairer.sync(pairer)
      set_clock(clock, 1_002)
      publish(:right, 996)
      Pairer.sync(pairer)

      assert_received {:"$gen_cast", {:submit, %Frame{}, %Frame{}, _pairer}}
      assert Pairer.latencies(pairer) == %{cameras: 5.0, pairing: 2.0}
    end

    test "starts over once asked" do
      {_clock, now_ns} = start_clock(1_000)
      pairer = start_timed_pairer(now_ns)

      for side <- [:left, :right], do: publish(side, 990)
      assert %{cameras: 10.0, pairing: +0.0} = Pairer.latencies(pairer)

      assert Pairer.latencies(pairer) == %{cameras: nil, pairing: nil}
    end

    test "has no pairing wait while no pair is submitted" do
      {_clock, now_ns} = start_clock(1_000)
      pairer = start_timed_pairer(now_ns)

      publish(:left, 997)

      assert Pairer.latencies(pairer) == %{cameras: 3.0, pairing: nil}
    end
  end

  describe ":max_hz" do
    @frame_period_ns div(1_000_000_000, 30)
    # A few ms early or late, as capture times are.
    @jitter_ms [0, 1, -2, 2, -1]

    defp start_capped_pairer(opts) do
      start_supervised!({Pairer, [cameras: @cameras, pipeline: self(), fps: 30] ++ opts})
    end

    # The capture times of `count` pairs at 30 fps, each a little early or late.
    defp jittered_ns(count) do
      for index <- 0..(count - 1),
          do: index * @frame_period_ns + Enum.at(@jitter_ms, rem(index, 5)) * 1_000_000
    end

    # 10 s of pairs from cameras set to 30 fps that deliver 29.97, alternately 3 ms late and early.
    defp measured_rate_ns do
      for index <- 0..299,
          do:
            div(index * 1_001_000_000, 30) +
              if(rem(index, 2) == 0, do: 3, else: -3) * 1_000_000
    end

    defp publish_pair(capture_ns) do
      for {side, offset_ns} <- [left: 0, right: 100_000],
          do: publish_frame(side, %{frame(label(side), 0) | capture_ns: capture_ns + offset_ns})
    end

    # Publishes a pair at each capture time, the pipeline taking each pair at once, and returns the times submitted.
    defp submitted_ns(pairer, captures_ns) do
      Enum.filter(captures_ns, fn capture_ns ->
        publish_pair(capture_ns)
        Pairer.sync(pairer)

        receive do
          {:"$gen_cast", {:submit, %Frame{capture_ns: ^capture_ns}, %Frame{}, _pairer}} ->
            send(pairer, :stereo_pipeline_ready)
            true
        after
          0 -> false
        end
      end)
    end

    defp capped_received do
      receive do
        {:"$gen_cast", {:stereo_pair_capped, _capture_ns}} -> 1 + capped_received()
      after
        0 -> 0
      end
    end

    test "at half the cameras' rate, submits every other pair, whatever their jitter" do
      pairer = start_capped_pairer(max_hz: 15)
      captures_ns = jittered_ns(12)

      assert submitted_ns(pairer, captures_ns) == Enum.take_every(captures_ns, 2)
    end

    for {max_hz, tolerance} <- [{10, 1}, {15, 1}, {20, 2}, {25, 2}] do
      test "at #{max_hz} Hz, submits #{max_hz} pairs a second of the cameras' 29.97, whatever their jitter" do
        pairer = start_capped_pairer(max_hz: unquote(max_hz))

        assert_in_delta length(submitted_ns(pairer, measured_rate_ns())),
                        unquote(max_hz) * 10,
                        unquote(tolerance)
      end
    end

    for max_hz <- [30, 0] do
      test "at #{max_hz} Hz, submits every pair of the cameras' 29.97 a second, whatever their jitter" do
        pairer = start_capped_pairer(max_hz: unquote(max_hz))
        captures_ns = measured_rate_ns()

        assert submitted_ns(pairer, captures_ns) == captures_ns
      end
    end

    test "without it, submits every pair" do
      pairer = start_capped_pairer([])
      captures_ns = jittered_ns(6)

      assert submitted_ns(pairer, captures_ns) == captures_ns
      assert Pairer.max_hz(pairer) == 0.0
    end

    test "publishes each pair it drops for its rate once, apart from those dropped while the pipeline is busy" do
      :ok = Outputs.subscribe(Pairer.capped_key())
      pairer = start_capped_pairer(max_hz: 15)
      [first, second, third, fourth] = jittered_ns(4)

      publish_pair(first)
      Pairer.sync(pairer)
      assert_received {:"$gen_cast", {:submit, %Frame{capture_ns: ^first}, _right, _pairer}}

      # Too soon after the first, though the pipeline is busy: dropped for the rate.
      publish_pair(second)
      Pairer.sync(pairer)
      assert_received {:"$gen_cast", {:stereo_pair_capped, ^second}}

      # Due, but the pipeline is busy: dropped as before, and the schedule waits for a pair submitted.
      publish_pair(third)
      Pairer.sync(pairer)
      publish_pair(fourth)
      Pairer.sync(pairer)
      assert capped_received() == 0
      refute_received {:"$gen_cast", {:submit, _left, _right, _pairer}}

      send(pairer, :stereo_pipeline_ready)
      Pairer.sync(pairer)
      assert_received {:"$gen_cast", {:submit, %Frame{capture_ns: ^fourth}, _right, _pairer}}
    end

    test "starts over from a pair captured before the last one submitted, as after a clock restart" do
      pairer = start_capped_pairer(max_hz: 15)
      [first, second, third, fourth] = jittered_ns(4)

      assert submitted_ns(pairer, [1_000_000_000, first, second, third, fourth]) ==
               [1_000_000_000, first, third]
    end

    test "changes while the pairer runs, from the next pair on, 0 submitting every pair" do
      pairer = start_capped_pairer(max_hz: 15)
      [first, second, third, fourth] = jittered_ns(4)

      assert Pairer.max_hz(pairer) == 15.0
      assert submitted_ns(pairer, [first, second]) == [first]

      assert Pairer.put_max_hz(pairer, 0) == :ok
      assert Pairer.max_hz(pairer) == 0.0
      assert submitted_ns(pairer, [third, fourth]) == [third, fourth]
    end

    test "refuses a rate that is no number from 0 to 1000, at start and while it runs" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Pairer.start_link(cameras: @cameras, pipeline: self(), max_hz: "15")

      assert message == "its :max_hz must be a number, got \"15\""

      pairer = start_capped_pairer([])
      assert Pairer.put_max_hz(pairer, -1) == {:error, "max_hz must be from 0 to 1000, got -1"}
    end
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
