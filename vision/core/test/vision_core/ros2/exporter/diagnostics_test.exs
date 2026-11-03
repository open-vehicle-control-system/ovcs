defmodule VisionCore.Ros2.Exporter.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.DiagnosticMsgs.Msg.DiagnosticArray
  alias Ros2Zenoh.StdMsgs.Msg.Float64
  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Ros2.Exporter.Diagnostics

  @half_period_ns 16_666_666

  # Names the cameras, which need not be running: without live/1, nothing is asked of them.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # Cameras that report what they apply, and are not running.
  defmodule StoppedCamera do
    def name_for(label), do: Module.concat(__MODULE__, label)
    def live(server), do: GenServer.call(server, :live)
  end

  defp start_diagnostics(driver) do
    test = self()

    start_supervised!(
      {Diagnostics,
       driver: driver,
       topic_prefix: "stereo",
       fps: 30,
       left: [sync: :server],
       right: [sync: :client],
       name: Module.concat(driver, Diagnostics),
       publish: fn topic, _module, message, _options ->
         send(test, {:published, topic, message})
         :ok
       end}
    )
  end

  test "measures the sync of the frames the cameras publish" do
    diagnostics = start_diagnostics(Camera)

    for {label, capture_ns} <- [{"left", 1_000_000_000}, {"right", 1_000_200_000}] do
      frame = %Frame{label: label, width: 1, height: 1, capture_ns: capture_ns, grey: <<0>>}
      Outputs.publish({:camera_frame, Camera.name_for(label)}, {:camera_frame, frame})
    end

    assert %{pairs: 1, offset_median_ms: offset_ms} = Diagnostics.sync(diagnostics)
    assert_in_delta offset_ms, 0.2, 1.0e-9
  end

  test "measures no sync once its cameras have formed no pair for two seconds" do
    diagnostics = start_diagnostics(Camera)

    for {label, capture_ns} <- [{"left", 1_000_000_000}, {"right", 1_000_200_000}] do
      frame = %Frame{label: label, width: 1, height: 1, capture_ns: capture_ns, grey: <<0>>}
      Outputs.publish({:camera_frame, Camera.name_for(label)}, {:camera_frame, frame})
    end

    assert %{pairs: 1} = Diagnostics.sync(diagnostics)

    # White-box: the pair formed two seconds and more ago.
    :sys.replace_state(diagnostics, fn state ->
      %{state | last_pair_ms: state.last_pair_ms - 2_001}
    end)

    assert Diagnostics.sync(diagnostics) == %{offset_median_ms: nil, offset_max_ms: nil, pairs: 0}
  end

  test "reports cameras that are not running as stale, and keeps running" do
    diagnostics = start_diagnostics(StoppedCamera)

    send(diagnostics, :diagnostics)

    assert_receive {:published, "/diagnostics", %DiagnosticArray{status: statuses}}, 1_000

    assert Enum.map(statuses, &{&1.name, &1.level}) == [
             {"stereo left camera", :stale},
             {"stereo right camera", :stale},
             {"stereo camera sync", :stale}
           ]

    send(diagnostics, :plot)
    assert %{pairs: 0} = Diagnostics.sync(diagnostics)
  end

  test "plots the sync offset and each camera's exposure and gain" do
    live = %{
      left: %{exposure_time_us: 1_000, analogue_gain: 2.0, received_ms: 0},
      right: %{exposure_time_us: nil, received_ms: 0}
    }

    assert [
             {"stereo/live/sync_offset_ms", Float64, %{data: 0.2}},
             {"stereo/live/left/exposure_time_us", Float64, %{data: 1000.0}},
             {"stereo/live/left/analogue_gain", Float64, %{data: 2.0}}
           ] = Diagnostics.plot_messages("stereo", [0.2, 0.1, 0.3], live)

    assert Diagnostics.plot_messages("stereo", [], %{left: nil, right: nil}) == []
  end

  test "reports synced cameras whose frames are close as ok, and frames too far apart as a warning" do
    live = fn ->
      %{
        left: %{received_ms: 1_000, sync_ready: true},
        right: %{received_ms: 1_000, sync_ready: true}
      }
    end

    roles = %{left: :server, right: :client}

    assert %DiagnosticArray{status: [_left, _right, sync]} =
             Diagnostics.diagnostic_array("stereo", roles, [0.2], live.(), 1_500, nil)

    assert %{level: :ok, message: "frames 0.20 ms apart"} = sync

    assert %DiagnosticArray{status: [_left, _right, %{level: :warn}]} =
             Diagnostics.diagnostic_array("stereo", roles, [1.5], live.(), 1_500, nil)
  end

  describe "pair_offset/4" do
    test "measures right minus left against the nearest frame of the other camera" do
      assert Diagnostics.pair_offset(
               :right,
               1_000_200_000,
               [1_000_000_000, 966_666_666],
               @half_period_ns
             ) ==
               200_000

      assert Diagnostics.pair_offset(
               :left,
               1_000_200_000,
               [1_000_000_000, 966_666_666],
               @half_period_ns
             ) ==
               -200_000
    end

    test "pairs nothing farther than half a frame period, nor without frames" do
      assert Diagnostics.pair_offset(
               :right,
               1_020_000_000,
               [1_000_000_000],
               @half_period_ns
             ) == nil

      assert Diagnostics.pair_offset(:right, 1_000_000_000, [], @half_period_ns) == nil
    end
  end
end
