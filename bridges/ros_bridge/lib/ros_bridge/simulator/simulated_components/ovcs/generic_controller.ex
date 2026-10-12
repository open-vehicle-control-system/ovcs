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

  @digital_pins 0..18
                |> Map.new(fn pin -> {"digital_pin#{pin}_enabled", false} end)
                |> Map.put("filler0", 0)
  # The controller reports zero once no edge has arrived for this long.
  @pulse_timeout_s 2.0
  @counter_range 65_536
  # The alive frame's period: its counter steps once per frame sent.
  @alive_period_s 0.1

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
      elapsed_s: 0.0,
      pulses: 0.0,
      since_pulse_s: nil
    }

    emitted =
      [
        {state.network, state.alive, alive(0)},
        {state.network, state.pin_status, pin_status(Map.get(opts, :analog_pins, %{}))}
      ] ++
        if(state.pulse,
          do: [{state.network, state.pulse_counter, pulse_counter(state, 0.0)}],
          else: []
        )

    {state, [], emitted}
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def step(state, vehicle, dt_s, _now_ms) do
    state = %{state | elapsed_s: state.elapsed_s + dt_s}

    alive =
      {state.network, state.alive, alive(rem(trunc(state.elapsed_s / @alive_period_s), 256))}

    case state.pulse do
      nil ->
        {state, [alive]}

      pulse ->
        pulses_per_wheel_turn = pulse.shaft_turns_per_wheel_turn * pulse.pulses_per_revolution
        step_pulses = abs(vehicle.wheel_turns_step) * pulses_per_wheel_turn
        state = count(state, step_pulses, dt_s)

        frequency =
          abs(vehicle.wall_speed_m_s) / (2 * :math.pi() * vehicle.wheel_radius_m) *
            pulses_per_wheel_turn

        {state, [alive, {state.network, state.pulse_counter, pulse_counter(state, frequency)}]}
    end
  end

  defp count(state, step_pulses, dt_s) do
    pulses = state.pulses + step_pulses

    since_pulse_s =
      cond do
        trunc(pulses) > trunc(state.pulses) -> 0.0
        is_nil(state.since_pulse_s) -> nil
        true -> state.since_pulse_s + dt_s
      end

    %{state | pulses: pulses, since_pulse_s: since_pulse_s}
  end

  @doc false
  def pulse_counter(state, frequency) do
    reported =
      if is_nil(state.since_pulse_s) or state.since_pulse_s > @pulse_timeout_s,
        do: 0.0,
        else: frequency

    %{
      "pulse_pin0_count" => rem(trunc(state.pulses), @counter_range),
      "pulse_pin0_frequency" => reported |> Decimal.from_float() |> Decimal.round(1)
    }
  end

  defp alive(counter) do
    %{
      "counter" => counter,
      "status" => "OK",
      "expansion_board1_last_error" => "OK",
      "expansion_board2_last_error" => "OK"
    }
  end

  defp pin_status(analog_pins) do
    Enum.reduce(0..2, @digital_pins, fn pin, signals ->
      Map.put(signals, "analog_pin#{pin}_value", Map.get(analog_pins, pin, 0))
    end)
  end
end
