defmodule VisionCore.StatusTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.ZenohClient
  alias VisionCore.Status
  alias VisionCore.Stereo.Pair

  defp config(components),
    do: %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: components}

  defp pair do
    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: 0, jpeg: <<>>}
    %Pair{left_frame: frame, right_frame: %{frame | label: "right"}}
  end

  test "snapshot reports zenoh disconnected with no router" do
    start_supervised!({ZenohClient, endpoint_ip: "127.0.0.1"})
    start_supervised!({Status, config: config([])})

    snapshot = Status.snapshot()

    assert snapshot.zenoh == :disconnected
    assert snapshot.cameras == %{left: %{present: false}, right: %{present: false}}
    assert snapshot.sync == %{present: false}
    assert snapshot.hailo == :absent
    assert snapshot.depth_hz == 0.0
  end

  test "a configured Hailo detector that is not running is reported failed" do
    start_supervised!({Status, config: config([{:hailo_detector, hef_path: "/missing.hef"}])})

    assert Status.snapshot().hailo == :failed
  end

  test "a detector that does not answer is reported failed without stalling the snapshot" do
    silent = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(silent, VisionCore.Detection.Backend.Hailo)
    on_exit(fn -> Process.exit(silent, :kill) end)
    start_supervised!({Status, config: config([:hailo_detector])})

    {elapsed_us, snapshot} = :timer.tc(&Status.snapshot/0)

    assert snapshot.hailo == :failed
    assert elapsed_us < 1_000_000
  end

  test "a new subscriber receives a snapshot at once" do
    start_supervised!({Status, config: config([]), tick_ms: 60_000})
    :ok = Status.subscribe()

    assert_receive {:vision_status, %{zenoh: :disconnected}}, 500
  end

  test "subscribers receive a snapshot every tick, with the depth rate" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()

    assert_receive {:vision_status, %{depth_hz: +0.0}}
    for _ <- 1..4, do: GenServer.cast(Status, {:stereo_pair, pair()})

    assert_receive {:vision_status, %{depth_hz: depth_hz}}, 500
    assert depth_hz > 0.0
  end

  test "each tick reports the row alignment averaged over its pairs" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, %{alignment: nil}}

    for offset <- [1.0, 2.0] do
      alignment = %{offset_rows: offset, band_offset_rows: [offset, offset, offset, offset]}
      GenServer.cast(Status, {:stereo_pair, %{pair() | alignment: alignment}})
    end

    assert_receive {:vision_status, %{alignment: %{offset_rows: 1.5, band_offset_rows: bands}}},
                   500

    assert bands == [1.5, 1.5, 1.5, 1.5]
  end

  test "each tick reports the cameras' sharpness averaged over its pairs" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, %{sharpness: nil}}

    for right <- [0.02, 0.04] do
      GenServer.cast(Status, {:stereo_pair, %{pair() | sharpness: %{left: 0.04, right: right}}})
    end

    assert_receive {:vision_status, %{sharpness: %{left: left, right: right}}}, 500
    assert_in_delta left, 0.04, 1.0e-9
    assert_in_delta right, 0.03, 1.0e-9
  end

  test "each tick reports the CPU usage and the stereo segment time" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, _first}

    # Four pairs of 25 ms in a 200 ms window: half the time in the segment.
    for _ <- 1..4, do: GenServer.cast(Status, {:stereo_pair, %{pair() | device_ms: 25.0}})

    assert_receive {:vision_status, %{cpu_percent: cpu, stereo_segment_percent: segment}}, 500
    assert cpu >= 0.0 and cpu <= 100.0
    assert_in_delta segment, 50.0, 15.0
  end
end
