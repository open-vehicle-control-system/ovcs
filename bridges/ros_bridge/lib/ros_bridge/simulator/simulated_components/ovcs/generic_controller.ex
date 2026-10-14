defmodule RosBridge.Simulator.SimulatedComponents.OVCS.GenericController do
  @moduledoc """
  An OVCS generic controller, the inverse of
  `VmsCore.Components.OVCS.GenericController`: alive with status `OK`,
  its digital and analog pin status, and, with `:pulse`, its pulse
  counter.

  It drives nothing itself. An actuator wired to one of its outputs is
  a simulated component of its own that reads the controller's request frame, such
  as `RosBridge.Simulator.SimulatedComponents.Traxxas.Steering`.

  ## Options

    * `:name` (`"main_controller"`) — the frame-name prefix, the VMS
      component's underscored process name.
    * `:network` (`:ovcs`).
    * `:analog_pins` (`%{}`) — fixed readings, pin to 14-bit count.
    * `:pulse` — a pulse sensor on pulse pin 0:
      `%{shaft_turns_per_wheel_turn: ratio, pulses_per_revolution: n}`.
      Without it no pulse counter frame is emitted.
  """
  @behaviour RosBridge.Simulator.SimulatedComponent

  import RosBridge.Simulator.SimulatedComponent, only: [decimal: 2]

  # The VMS reads the status and the board errors, never the counter.
  @alive %{
    "counter" => 0,
    "status" => "OK",
    "expansion_board1_last_error" => "OK",
    "expansion_board2_last_error" => "OK"
  }

  @digital_pins 0..18
                |> Map.new(fn pin -> {"digital_pin#{pin}_enabled", false} end)
                |> Map.put("filler0", 0)
  # The controller reports zero once no edge has arrived for this long.
  @pulse_timeout_ms 2_000
  @counter_range 65_536

  @impl RosBridge.Simulator.SimulatedComponent
  def init(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, "main_controller")

    state = %{
      network: Map.get(opts, :network, :ovcs),
      alive: "#{name}_alive",
      pin_status: "#{name}_digital_and_analog_pin_status",
      pulse_counter: "#{name}_pulse_counter_status",
      pulse: Map.get(opts, :pulse),
      pulses: 0.0,
      last_pulse_ms: nil
    }

    emitted =
      [
        {state.network, state.alive, @alive},
        {state.network, state.pin_status, pin_status(Map.get(opts, :analog_pins, %{}))}
      ] ++
        if(state.pulse,
          do: [{state.network, state.pulse_counter, pulse_counter(state, 0.0, 0)}],
          else: []
        )

    {state, [], emitted}
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def report(state, vehicle, now_ms) do
    case state.pulse do
      nil ->
        {state, []}

      pulse ->
        pulses_per_wheel_turn = pulse.shaft_turns_per_wheel_turn * pulse.pulses_per_revolution
        step_pulses = abs(vehicle.wheel_turns_step) * pulses_per_wheel_turn
        state = count(state, step_pulses, now_ms)

        frequency =
          abs(vehicle.measured_speed_m_s) / (2 * :math.pi() * vehicle.wheel_radius_m) *
            pulses_per_wheel_turn

        {state, [{state.network, state.pulse_counter, pulse_counter(state, frequency, now_ms)}]}
    end
  end

  defp count(state, step_pulses, now_ms) do
    pulses = state.pulses + step_pulses

    last_pulse_ms =
      if floor(pulses) > floor(state.pulses), do: now_ms, else: state.last_pulse_ms

    %{state | pulses: pulses, last_pulse_ms: last_pulse_ms}
  end

  defp pulse_counter(state, frequency, now_ms) do
    reported =
      if is_nil(state.last_pulse_ms) or now_ms - state.last_pulse_ms > @pulse_timeout_ms,
        do: 0.0,
        else: frequency

    %{
      "pulse_pin0_count" => rem(floor(state.pulses), @counter_range),
      "pulse_pin0_frequency" => decimal(reported, 1)
    }
  end

  defp pin_status(analog_pins) do
    Enum.reduce(0..2, @digital_pins, fn pin, signals ->
      Map.put(signals, "analog_pin#{pin}_value", Map.get(analog_pins, pin, 0))
    end)
  end
end
