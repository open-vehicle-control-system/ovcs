defmodule SimulatorCore.SimulatedComponents.OVCS.GenericController do
  @moduledoc """
  An OVCS generic controller, the inverse of
  `VmsCore.Components.OVCS.GenericController`: alive with status `OK`,
  its digital and analog pin status, and, with `:pulse`, its pulse
  counter.

  Its digital pins report what the VMS last requested on its digital
  pin request frame, as the board's relays do once they switch: the VMS
  checks a relay by the status it reads back, not by its request.

  It drives nothing itself. An actuator wired to one of its outputs is
  a simulated component of its own that reads the controller's request frame, such
  as `SimulatorCore.SimulatedComponents.Traxxas.Steering`.

  ## Options

    * `:name` (`"main_controller"`) — the frame-name prefix, the VMS
      component's underscored process name.
    * `:network` (`:ovcs`).
    * `:analog_pins` (`%{}`) — fixed readings, pin to 14-bit count.
    * `:pulse` — a pulse sensor on pulse pin 0:
      `%{shaft_turns_per_wheel_turn: ratio, pulses_per_revolution: n}`.
      Without it no pulse counter frame is emitted.
  """
  @behaviour SimulatorCore.SimulatedComponent

  import SimulatorCore.SimulatedComponent, only: [decimal: 2]

  # The VMS reads the status and the board errors, never the counter.
  @alive %{
    "counter" => 0,
    "status" => "OK",
    "expansion_board1_last_error" => "OK",
    "expansion_board2_last_error" => "OK"
  }

  @digital_pin_names Enum.map(0..18, &"digital_pin#{&1}_enabled")
  @digital_pins @digital_pin_names |> Map.new(&{&1, false}) |> Map.put("filler0", 0)
  # The controller reports zero once no edge has arrived for this long.
  @pulse_timeout_ms 2_000
  @counter_range 65_536

  @impl SimulatorCore.SimulatedComponent
  def init(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, "main_controller")

    state = %{
      network: Map.get(opts, :network, :ovcs),
      alive: "#{name}_alive",
      pin_request: "#{name}_digital_pin_request",
      pin_status: "#{name}_digital_and_analog_pin_status",
      pulse_counter: "#{name}_pulse_counter_status",
      pins: pin_status(Map.get(opts, :analog_pins, %{})),
      pins_changed: false,
      pulse: Map.get(opts, :pulse),
      pulses: 0.0,
      last_pulse_ms: nil
    }

    emitted =
      [
        {state.network, state.alive, @alive},
        {state.network, state.pin_status, state.pins}
      ] ++
        if(state.pulse,
          do: [{state.network, state.pulse_counter, pulse_counter(state, 0.0, 0)}],
          else: []
        )

    {state, [{state.network, state.pin_request}], emitted}
  end

  @impl SimulatorCore.SimulatedComponent
  def handle_frame(name, signals, %{pin_request: name} = state, _now_ms) do
    requested =
      signals
      |> Map.take(@digital_pin_names)
      |> Map.new(fn {pin, signal} -> {pin, signal.value} end)

    pins = Map.merge(state.pins, requested)
    %{state | pins: pins, pins_changed: state.pins_changed or pins != state.pins}
  end

  @impl SimulatorCore.SimulatedComponent
  def report(state, vehicle, now_ms) do
    {state, pins} = report_pins(state)
    {state, pulses} = report_pulses(state, vehicle, now_ms)
    {state, pins ++ pulses}
  end

  defp report_pins(%{pins_changed: false} = state), do: {state, []}

  defp report_pins(state),
    do: {%{state | pins_changed: false}, [{state.network, state.pin_status, state.pins}]}

  defp report_pulses(%{pulse: nil} = state, _vehicle, _now_ms), do: {state, []}

  defp report_pulses(%{pulse: pulse} = state, vehicle, now_ms) do
    pulses_per_wheel_turn = pulse.shaft_turns_per_wheel_turn * pulse.pulses_per_revolution
    step_pulses = abs(vehicle.wheel_turns_step) * pulses_per_wheel_turn
    state = count(state, step_pulses, now_ms)

    frequency =
      abs(vehicle.measured_speed_m_s) / (2 * :math.pi() * vehicle.wheel_radius_m) *
        pulses_per_wheel_turn

    {state, [{state.network, state.pulse_counter, pulse_counter(state, frequency, now_ms)}]}
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
