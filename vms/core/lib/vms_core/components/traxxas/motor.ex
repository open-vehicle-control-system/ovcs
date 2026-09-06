defmodule VmsCore.Components.Traxxas.Motor do
  @moduledoc """
  Motor speed from a hall effect sensor.

  The sensor's pulse train is counted by the generic controller, which
  reports a frequency on its pulse counter frame. This turns that
  frequency into the speed of the sensed shaft and of the vehicle:

      shaft rpm   = frequency · 60 / pulses_per_revolution
      wheel rev/s = frequency / pulses_per_revolution / gear_ratio
      speed       = wheel rev/s · 2π · wheel_radius

  `:speed` is published in km/h, the unit every other `:speed` on the
  bus uses.

  ## Standstill, and not knowing

  The controller reports a frequency of zero once no edge has arrived
  for two seconds, so `:speed` reads exactly zero at rest and
  `Managers.ControlLevel`'s standstill gate holds. The same two seconds
  set the slowest speed that reads as motion at all, about 0.2 km/h on
  the Mini.

  When the controller's pulse frame is not arriving, the generic
  controller publishes a nil frequency and this publishes a nil speed.
  Nil is not zero: the manager refuses mode changes it cannot prove
  safe rather than treating silence as a standstill.

  ## Options

    * `:controller` — the generic controller the sensor is wired to, on
      its pulse pin 0, the only one a controller has.
    * `:pulses_per_revolution` — edges per turn of the shaft the magnet
      is on.
    * `:gear_ratio` — turns of that shaft per turn of the wheel.
    * `:wheel_radius` — metres, from the vehicle's `geometry/0`.

  The product `pulses_per_revolution · gear_ratio` is the only thing
  that matters, and it is measured by rolling the vehicle one wheel
  turn and counting pulses.
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus

  @loop_period 10
  @frequency_name :received_pulse_pin0_frequency

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
        controller: controller,
        pulses_per_revolution: pulses_per_revolution,
        gear_ratio: gear_ratio,
        wheel_radius: wheel_radius
      }) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    # Unknown until the controller says otherwise. Zero here would let
    # the standstill gate pass before the first frequency arrives, or
    # for ever if the controller named here never publishes one.
    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       pulses_per_revolution: pulses_per_revolution,
       speed_factor: speed_factor(pulses_per_revolution, gear_ratio, wheel_radius),
       rotation_per_minute: nil,
       speed: nil
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    {:noreply, emit_metrics(state)}
  end

  # Computed when the frequency arrives, not on every tick: the
  # constants are fixed and the frequency only changes with a message.
  def handle_info(%Bus.Message{name: @frequency_name, value: nil, source: source}, state)
      when source == state.controller do
    {:noreply, %{state | rotation_per_minute: nil, speed: nil}}
  end

  def handle_info(%Bus.Message{name: @frequency_name, value: frequency, source: source}, state)
      when source == state.controller do
    {:noreply,
     %{
       state
       | rotation_per_minute: rotation_per_minute(frequency, state.pulses_per_revolution),
         speed: speed_km_h(frequency, state.speed_factor)
     }}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  # The frequency arrives with one decimal (`0x7X9` decodes at
  # precision 1), so the result carries one too: `6000.0`, not `6000`.
  @doc false
  def rotation_per_minute(frequency, pulses_per_revolution) do
    frequency |> D.new() |> D.mult(60) |> D.div(pulses_per_revolution)
  end

  # km/h per hertz, fixed at init: one wheel circumference per
  # `pulses_per_revolution · gear_ratio` pulses.
  @doc false
  def speed_factor(pulses_per_revolution, gear_ratio, wheel_radius) do
    wheel_circumference = 2 * :math.pi() * wheel_radius
    D.from_float(wheel_circumference * 3.6 / (pulses_per_revolution * gear_ratio))
  end

  @doc false
  def speed_km_h(frequency, speed_factor) do
    frequency |> D.new() |> D.mult(speed_factor) |> D.round(2)
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :rotation_per_minute,
      value: state.rotation_per_minute,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{name: :speed, value: state.speed, source: __MODULE__})

    state
  end
end
