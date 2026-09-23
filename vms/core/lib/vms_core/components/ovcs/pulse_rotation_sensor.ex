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

  `:rotation_per_minute` goes out once per frequency the controller
  reports, not on a timer: each message is a fresh sample, which is
  what lets `VehicleMotion` tell an integrator that the data moved.

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
  alias OvcsBus.Units

  @frequency_name :received_pulse_pin0_frequency

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{controller: controller, pulses_per_revolution: pulses_per_revolution}) do
    Bus.subscribe("messages")

    {:ok,
     %{
       controller: controller,
       pulses_per_revolution: D.new(pulses_per_revolution)
     }}
  end

  @impl true
  def handle_info(%Bus.Message{name: @frequency_name, value: frequency, source: source}, state)
      when source == state.controller do
    Bus.broadcast("messages", %Bus.Message{
      name: :rotation_per_minute,
      value: rotation_per_minute(frequency, state.pulses_per_revolution),
      unit: Units.revolution_per_minute(),
      source: __MODULE__
    })

    {:noreply, state}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  # The frequency arrives with one decimal (`0x7X9` decodes at
  # precision 1), so the result carries one too: `600.0`, not `600`.
  @doc false
  def rotation_per_minute(nil, _pulses_per_revolution), do: nil

  def rotation_per_minute(frequency, pulses_per_revolution) do
    frequency |> D.new() |> D.mult(60) |> D.div(pulses_per_revolution) |> D.round(1)
  end
end
