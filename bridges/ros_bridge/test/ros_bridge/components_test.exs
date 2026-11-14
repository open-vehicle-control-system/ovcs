defmodule RosBridge.ComponentsTest do
  use ExUnit.Case, async: true

  alias RosBridge.Components

  describe "start/2 — :heartbeat" do
    test "returns a single RosBridge.Publishers.Heartbeat child spec with defaults" do
      assert [{RosBridge.Publishers.Heartbeat, opts}] = Components.start(:heartbeat, [])
      refute Keyword.has_key?(opts, :topic)
      assert opts[:message_module] == Ros2Zenoh.StdMsgs.Msg.String
      assert opts[:interval_ms] == 1_000
      assert is_function(opts[:build], 2)
    end

    test "each heartbeat names the bridge that sent it" do
      [{RosBridge.Publishers.Heartbeat, opts}] = Components.start(:heartbeat, [])

      assert %{data: "ovcs_bridge_ros heartbeat 7 @ " <> _ms} =
               opts[:build].(7, "ovcs_bridge_ros")
    end

    test "publishes under the bridge's node name" do
      assert RosBridge.Publishers.Heartbeat.topic("ovcs_bridge_ros") ==
               "ovcs_bridge_ros/heartbeat"
    end

    test ":interval_ms overrides the default" do
      [{RosBridge.Publishers.Heartbeat, opts}] = Components.start(:heartbeat, interval_ms: 5_000)
      assert opts[:interval_ms] == 5_000
    end
  end

  describe "start/2 — :joy_interpreter" do
    test "returns a single RosBridge.Consumers.Joy child spec" do
      assert [{RosBridge.Consumers.Joy, []}] = Components.start(:joy_interpreter, [])
    end
  end

  describe "start/2 — :imu_publisher" do
    test "returns the driver and publisher child specs in start order" do
      defmodule FakeImu do
      end

      [driver_spec, publisher_spec] = Components.start(:imu_publisher, driver: FakeImu)
      assert driver_spec == {FakeImu, []}
      assert {RosBridge.Publishers.Imu, opts} = publisher_spec
      assert opts[:driver] == FakeImu
    end

    test "forwards optional publisher opts (topic, frame_id, publish_interval_ms)" do
      [_driver_spec, {RosBridge.Publishers.Imu, opts}] =
        Components.start(:imu_publisher,
          driver: RosBridge.ComponentsTest.FakeImu,
          topic: "imu/raw",
          frame_id: "chassis_link",
          publish_interval_ms: 40
        )

      assert opts[:topic] == "imu/raw"
      assert opts[:frame_id] == "chassis_link"
      assert opts[:publish_interval_ms] == 40
    end

    test "raises if :driver is missing" do
      assert_raise KeyError, fn -> Components.start(:imu_publisher, []) end
    end
  end

  describe "start/2 — :simulated_hardware" do
    test "runs the simulator's loop against Gazebo, which reads the wheel joints" do
      vehicle = %{wheelbase_m: 0.3, wheel_radius_m: 0.05}

      assert [{SimulatorCore.Hardware, opts}] =
               Components.start(:simulated_hardware,
                 vehicle: vehicle,
                 simulated_components: [],
                 wheel_joints: ["rear_wheel"]
               )

      assert opts == %{
               vehicle: vehicle,
               simulated_components: [],
               world: {RosBridge.Simulator.World, wheel_joints: ["rear_wheel"]}
             }
    end
  end

  test "unknown component raises FunctionClauseError at boot" do
    assert_raise FunctionClauseError, fn -> Components.start(:not_a_component, []) end
  end
end
