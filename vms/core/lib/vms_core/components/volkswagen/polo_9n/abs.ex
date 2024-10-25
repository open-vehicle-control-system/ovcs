defmodule VmsCore.Components.Volkswagen.Polo9N.ABS do
  @moduledoc """
    Polo ABS
  """
  use GenServer
  alias VmsCore.Bus

  require Logger
  alias Cantastic.{Frame, Receiver, Signal}
  alias Decimal, as: D

  @loop_period 10
  @zero D.new(0)

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :polo_drive, ["abs_status", "wheels_speed"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      speed: @zero,
      front_left_wheel_speed: @zero,
      front_right_wheel_speed: @zero,
      rear_left_wheel_speed: @zero,
      rear_right_wheel_speed: @zero,
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    Bus.broadcast("messages", %Bus.Message{name: :speed, value: state.speed, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :front_left_wheel_speed, value: state.front_left_wheel_speed, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :front_right_wheel_speed, value: state.front_right_wheel_speed, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :rear_left_wheel_speed, value: state.rear_left_wheel_speed, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :rear_right_wheel_speed, value: state.rear_right_wheel_speed, source: __MODULE__})
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: "abs_status", signals: signals}}, state) do
    %{"speed" => %Signal{value: speed}} = signals
    {:noreply, %{state | speed: speed}}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: "wheels_speed", signals: signals}}, state) do
    %{
      "front_left_wheel_speed" => %Signal{value: front_left_wheel_speed},
      "front_right_wheel_speed" => %Signal{value: front_right_wheel_speed},
      "rear_left_wheel_speed" => %Signal{value: rear_left_wheel_speed},
      "rear_right_wheel_speed" => %Signal{value: rear_right_wheel_speed},
    } = signals
    {:noreply, %{state |
      front_left_wheel_speed: front_left_wheel_speed,
      front_right_wheel_speed: front_right_wheel_speed,
      rear_left_wheel_speed: rear_left_wheel_speed,
      rear_right_wheel_speed: rear_right_wheel_speed
    }}
  end
end
