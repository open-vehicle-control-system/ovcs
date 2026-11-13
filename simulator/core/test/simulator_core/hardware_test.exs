defmodule SimulatorCore.HardwareTest do
  # The loop registers its name, hence not async.
  use ExUnit.Case, async: false

  alias SimulatorCore.{Hardware, Vehicle}

  @moduletag :capture_log

  # Ticks run on a real 20 ms timer, which a loaded machine delays.
  @tick_timeout_ms 1_000

  defmodule TestWorld do
    @behaviour SimulatorCore.World

    # Runs in the loop before its first tick: a first sample, if any, is read by that tick.
    @impl SimulatorCore.World
    def init(opts) do
      opts = Map.new(opts)
      if turns = opts[:first_wheel_turns], do: send(self(), {:wheel_turns, turns})
      opts
    end

    @impl SimulatorCore.World
    def wheel_turns({:wheel_turns, turns}, _state), do: turns
    def wheel_turns(_message, _state), do: nil

    @impl SimulatorCore.World
    def drive(vehicle, state) do
      send(state.test, {:drive, vehicle})
      :ok
    end
  end

  # Commands a speed and reports the motion it is shown; reads and emits no frame.
  defmodule SpeedController do
    @behaviour SimulatorCore.SimulatedComponent

    @impl SimulatorCore.SimulatedComponent
    def init(opts), do: {Map.new(opts), [], []}

    @impl SimulatorCore.SimulatedComponent
    def actuations(state, _vehicle, _now_ms), do: [{:speed, state.speed_m_s}]

    @impl SimulatorCore.SimulatedComponent
    def report(state, vehicle, _now_ms) do
      send(state.test, {:report, vehicle})
      {state, []}
    end
  end

  defp start_hardware(speed_m_s, world_opts \\ []) do
    start_supervised!(
      {Hardware,
       vehicle: %{wheelbase_m: 0.324, wheel_radius_m: 0.0522},
       simulated_components: [{SpeedController, speed_m_s: speed_m_s, test: self()}],
       world: {TestWorld, Keyword.put(world_opts, :test, self())}}
    )
  end

  defp start_headless(speed_m_s) do
    start_supervised!(
      {Hardware,
       vehicle: %{wheelbase_m: 0.324, wheel_radius_m: 0.0522},
       simulated_components: [{SpeedController, speed_m_s: speed_m_s, test: self()}]}
    )
  end

  test "drives the world at the commanded speed, measured as commanded before the world reports the wheels" do
    start_hardware(1.0)

    assert_receive {:drive, %Vehicle{commanded_speed_m_s: 1.0, measured_speed_m_s: 1.0}},
                   @tick_timeout_ms
  end

  test "reports the tick's motion to the simulated components" do
    start_hardware(0.2)

    assert_receive {:report, %Vehicle{commanded_speed_m_s: 0.2, measured_speed_m_s: 0.2}},
                   @tick_timeout_ms
  end

  test "steps the wheels by the change between the world's reports" do
    hardware = start_hardware(0.2, first_wheel_turns: 3.0)
    assert_receive {:report, %Vehicle{wheel_turns_step: +0.0}}, @tick_timeout_ms

    send(hardware, {:wheel_turns, 3.5})
    assert_receive {:report, %Vehicle{wheel_turns_step: 0.5}}, @tick_timeout_ms
  end

  test "the wheels' turn since the last tick: none before a sample, zero for the first" do
    assert Hardware.wheel_turns_step(nil, nil) == nil
    assert Hardware.wheel_turns_step(4.25, nil) == 0.0
    assert Hardware.wheel_turns_step(4.25, 4.0) == 0.25
  end

  describe "without a world" do
    test "the vehicle follows its own motion: the wheels turn as commanded" do
      start_headless(0.3)

      assert_receive {:report, %Vehicle{measured_speed_m_s: 0.3, wheel_turns_step: turns}},
                     @tick_timeout_ms

      assert turns > 0
    end

    test "ignores messages it has no world to read them for" do
      hardware = start_headless(0.2)

      send(hardware, :unrelated)

      assert_receive {:report, %Vehicle{commanded_speed_m_s: 0.2}}, @tick_timeout_ms
      assert Process.alive?(hardware)
    end
  end

  test "ignores a message the world does not read" do
    hardware = start_hardware(0.2)

    send(hardware, :unrelated)

    assert_receive {:drive, %Vehicle{commanded_speed_m_s: 0.2}}, @tick_timeout_ms
    assert Process.alive?(hardware)
  end
end
