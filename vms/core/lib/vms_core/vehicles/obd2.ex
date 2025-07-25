defmodule VmsCore.Vehicles.OBD2 do
  @moduledoc """
    Implements a basic OBD2 mapper reading RPM and speed
  """
  use GenServer
  require Logger
  alias VmsCore.{Bus}
  alias Decimal, as: D
  alias Cantastic.{Signal, Receiver, Emitter, Frame}

  @zero D.new(0)
  @loop_period 20

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      rotation_per_minute: @zero,
      speed: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> request()
      |> emit_metrics()

    {:noreply, state}
  end

  defp request(state) do
    request = <<0x010C0D::big-integer-size(24)>>
    {:ok, response} = Cantastic.ISOTPRequest.send(VmsCore.Vehicles.OBD2.Request, request)
    <<
      0x41::integer-size(8), # Mode
      0x0C::integer-size(8), # RPM PID
      rpm_value::integer-big-size(16), # RPM value
      0x0D::integer-size(8), # Speed PID
      speed_value::integer-big-size(8),
    >> = response
    rotation_per_minute =  rpm_value |> D.mult("0.25")
    speed = D.new(speed_value)

    %{state | rotation_per_minute: rotation_per_minute, speed: speed}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :rotation_per_minute, value: state.rotation_per_minute, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :speed, value: state.speed, source: __MODULE__})
    state
  end
end
