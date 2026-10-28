defmodule VisionCore.StatusTest do
  use ExUnit.Case, async: false

  alias VisionCore.StereoCamera.Result
  alias VisionCore.Ros2.ZenohClient
  alias VisionCore.Status

  defp config(components),
    do: %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: components}

  defp result do
    %Result{
      capture_ns: 0,
      width: 2,
      height: 2,
      disparity: <<>>,
      disparity_step: 8,
      depth: <<>>,
      depth_step: 4,
      focal_length: 1.0,
      baseline: 0.1,
      min_disparity: 0.0,
      max_disparity: 64.0,
      delta_d: 0.0625,
      valid_x: 0,
      valid_y: 0,
      valid_w: 2,
      valid_h: 2,
      cloud: nil,
      cloud_points: 0
    }
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
    Process.register(silent, VisionCore.Inference.Hailo)
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
    for _ <- 1..4, do: GenServer.cast(Status, {:stereo_result, result()})

    assert_receive {:vision_status, %{depth_hz: depth_hz}}, 500
    assert depth_hz > 0.0
  end
end
