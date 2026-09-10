defmodule VmsCore.Components.OVCS.PulseRotationSensor do
  @moduledoc """
  The rotation of a shaft, from a magnet passing a switch.

  The sensor closes once per turn of whatever shaft it is mounted on —
  a spur gear, a half shaft, a wheel hub. The generic controller counts
  its pulses by interrupt and reports a frequency on its pulse counter
  frame. This turns that frequency into the shaft's rotation:

      rotation_per_minute = frequency · 60 / pulses_per_revolution

  That is all the sensor can prove. What the shaft's rotation means for
  the vehicle — how many times it turns per wheel turn, how big the
  wheel is — is the vehicle's kinematics, and `OVCS.VehicleMotion`
  owns it. A switch cannot tell which way the shaft turns either, so
  the rotation is unsigned; `VehicleMotion` takes the direction from
  the command.

  ## Standstill, and not knowing

  The controller reports a frequency of zero once no edge has arrived
  for two seconds, so `:rotation_per_minute` reads exactly zero at rest
  and the standstill gate downstream holds. The same two seconds set
  the slowest rotation that reads as motion at all, 30 rpm of the shaft.

  When the controller's pulse frame is not arriving, the generic
  controller publishes a nil frequency and this publishes a nil
  rotation. Nil is not zero: silence is not standstill.

  ## Options

    * `:controller` — the generic controller the sensor is wired to, on
      its pulse pin 0, the only one a controller has.
    * `:pulses_per_revolution` — edges per turn of the sensed shaft.
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
  def init(%{controller: controller, pulses_per_revolution: pulses_per_revolution}) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    # Unknown until the controller says otherwise. Zero here would read
    # as a standstill before the first frequency arrives, or for ever
    # if the controller named here never publishes one.
    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       pulses_per_revolution: D.new(pulses_per_revolution),
       rotation_per_minute: nil
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :rotation_per_minute,
      value: state.rotation_per_minute,
      source: __MODULE__
    })

    {:noreply, state}
  end

  # Computed when the frequency arrives, not on every tick: the
  # constant is fixed and the frequency only changes with a message.
  def handle_info(%Bus.Message{name: @frequency_name, value: nil, source: source}, state)
      when source == state.controller do
    {:noreply, %{state | rotation_per_minute: nil}}
  end

  def handle_info(%Bus.Message{name: @frequency_name, value: frequency, source: source}, state)
      when source == state.controller do
    {:noreply,
     %{
       state
       | rotation_per_minute: rotation_per_minute(frequency, state.pulses_per_revolution)
     }}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  # The frequency arrives with one decimal (`0x7X9` decodes at
  # precision 1), so the result carries one too: `600.0`, not `600`.
  @doc false
  def rotation_per_minute(frequency, pulses_per_revolution) do
    frequency |> D.new() |> D.mult(60) |> D.div(pulses_per_revolution) |> D.round(1)
  end
end
