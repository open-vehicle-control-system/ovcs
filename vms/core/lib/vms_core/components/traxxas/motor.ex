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
  bus uses. `:moving` is derived from it.

  ## Standstill

  The controller reports a frequency of zero once no edge has arrived
  for a second, so `:speed` reads exactly zero at rest and
  `Managers.ControlLevel`'s standstill gate holds. The same second sets
  the slowest speed that reads as motion at all.

  ## Options

    * `:controller` — the generic controller the sensor is wired to.
    * `:pulse_pin` — its pulse pin index (`0`).
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
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(
        %{
          controller: controller,
          pulses_per_revolution: pulses_per_revolution,
          gear_ratio: gear_ratio,
          wheel_radius: wheel_radius
        } = args
      ) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    pulse_pin = Map.get(args, :pulse_pin, 0)

    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       frequency_name: :"received_pulse_pin#{pulse_pin}_frequency",
       pulses_per_revolution: pulses_per_revolution,
       gear_ratio: gear_ratio,
       wheel_radius: wheel_radius,
       frequency: @zero,
       rotation_per_minute: @zero,
       speed: @zero,
       moving: false
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    state =
      state
      |> compute_values()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: name, value: frequency, source: source}, state)
      when source == state.controller and name == state.frequency_name do
    {:noreply, %{state | frequency: D.new(frequency)}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp compute_values(state) do
    speed = speed_km_h(state.frequency, state)

    %{
      state
      | rotation_per_minute: rotation_per_minute(state.frequency, state.pulses_per_revolution),
        speed: speed,
        moving: D.gt?(speed, @zero)
    }
  end

  @doc false
  def rotation_per_minute(frequency, pulses_per_revolution) do
    frequency |> D.mult(60) |> D.div(D.from_float(pulses_per_revolution / 1))
  end

  @doc false
  def speed_km_h(frequency, %{
        pulses_per_revolution: pulses_per_revolution,
        gear_ratio: gear_ratio,
        wheel_radius: wheel_radius
      }) do
    wheel_circumference = 2 * :math.pi() * wheel_radius
    metres_per_pulse = wheel_circumference / (pulses_per_revolution * gear_ratio)

    frequency
    |> D.mult(D.from_float(metres_per_pulse * 3.6))
    |> D.round(2)
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :rotation_per_minute,
      value: state.rotation_per_minute,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{name: :speed, value: state.speed, source: __MODULE__})

    Bus.broadcast("messages", %Bus.Message{name: :moving, value: state.moving, source: __MODULE__})

    state
  end
end
