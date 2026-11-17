defmodule SimulatorCore.HardwareTest do
  # The loop registers its name, hence not async.
  use ExUnit.Case, async: false

  alias SimulatorCore.{Efforts, Hardware, WorldState}

  @moduletag :capture_log

  # Ticks run on a real 20 ms timer, which a loaded machine delays.
  @tick_timeout_ms 1_000
  @wheel_radius_m 0.0522
  @vehicle %{wheelbase_m: 0.324, wheel_radius_m: @wheel_radius_m, mass_kg: 2.41}

  defmodule TestWorld do
    @behaviour SimulatorCore.World

    @impl SimulatorCore.World
    def init(opts), do: Map.new(opts)

    @impl SimulatorCore.World
    def actuate(efforts, _dt_s, state) do
      send(state.test, {:actuate, efforts})
      state
    end

    @impl SimulatorCore.World
    def world_state({:world_state, world}, state), do: {world, state}
    def world_state(_message, _state), do: nil
  end

  # Drives by a set torque and reports the world it is shown; reads and emits no frame.
  defmodule TorqueDriver do
    @behaviour SimulatorCore.SimulatedComponent

    @impl SimulatorCore.SimulatedComponent
    def init(opts), do: {Map.new(opts), [], []}

    @impl SimulatorCore.SimulatedComponent
    def efforts(state, _world, _now_ms), do: [{:drive_torque_nm, state.torque_nm}]

    @impl SimulatorCore.SimulatedComponent
    def measure(state, world, _now_ms) do
      send(state.test, {:report, world})
      {state, []}
    end
  end

  # A part still on the callbacks of the speed model: accelerates, and reports the motion it is shown.
  defmodule OldAccelerator do
    @behaviour SimulatorCore.SimulatedComponent

    @impl SimulatorCore.SimulatedComponent
    def init(opts), do: {Map.new(opts), [], []}

    @impl SimulatorCore.SimulatedComponent
    def actuations(state, _vehicle, _now_ms), do: [{:acceleration, state.acceleration_m_s2}]

    @impl SimulatorCore.SimulatedComponent
    def report(state, vehicle, _now_ms) do
      send(state.test, {:old_report, vehicle})
      {state, []}
    end
  end

  defp start_hardware(torque_nm, world \\ nil) do
    options = [
      vehicle: @vehicle,
      simulated_components: [{TorqueDriver, torque_nm: torque_nm, test: self()}]
    ]

    options = if world, do: Keyword.put(options, :world, world), else: options
    start_supervised!({Hardware, options})
  end

  describe "with a world" do
    test "hands the world the tick's efforts" do
      start_hardware(1.0, {TestWorld, test: self()})

      assert_receive {:actuate, %Efforts{drive_torque_nm: 1.0}}, @tick_timeout_ms
    end

    test "before the world reports, the parts measure a vehicle at rest" do
      start_hardware(1.0, {TestWorld, test: self()})

      at_rest = WorldState.at_rest(@wheel_radius_m)
      assert_receive {:report, ^at_rest}, @tick_timeout_ms
    end

    test "the parts measure the world's latest state" do
      hardware = start_hardware(1.0, {TestWorld, test: self()})
      spinning = put_in(WorldState.at_rest(@wheel_radius_m).wheels[:rear_left].omega_rad_s, 5.0)

      send(hardware, {:world_state, spinning})

      assert_receive {:report, ^spinning}, @tick_timeout_ms
    end

    test "ignores a message the world does not read" do
      hardware = start_hardware(1.0, {TestWorld, test: self()})

      send(hardware, :unrelated)

      assert_receive {:actuate, _efforts}, @tick_timeout_ms
      assert Process.alive?(hardware)
    end
  end

  describe "a part on the speed model's callbacks" do
    test "drives the vehicle through its mass, and measures its speed and wheel turns" do
      start_supervised!(
        {Hardware,
         vehicle: @vehicle,
         simulated_components: [{OldAccelerator, acceleration_m_s2: 1.0, test: self()}]}
      )

      assert_receive {:old_report, %{measured_speed_m_s: speed, wheel_turns_step: turns}}
                     when speed > 0 and turns > 0,
                     @tick_timeout_ms
    end
  end

  describe "without a world" do
    test "the efforts drive the flat ground, and the parts measure its wheels turning" do
      start_hardware(0.05)

      assert_receive {:report, %WorldState{wheels: %{front_left: %{omega_rad_s: omega}}}}
                     when omega > 0,
                     @tick_timeout_ms
    end

    test "ignores messages it has no world to read them for" do
      hardware = start_hardware(0.05)

      send(hardware, :unrelated)

      assert_receive {:report, _world}, @tick_timeout_ms
      assert Process.alive?(hardware)
    end
  end
end
