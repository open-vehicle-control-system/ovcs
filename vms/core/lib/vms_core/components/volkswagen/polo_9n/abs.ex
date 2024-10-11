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
    :ok = Receiver.subscribe(self(), :polo_drive, "abs_status")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      speed: @zero
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    Bus.broadcast("messages", %Bus.Message{name: :speed, value: state.speed, source: __MODULE__})
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{signals: signals}}, state) do
    %{"speed" => %Signal{value: speed}} = signals
    {:noreply, %{state | speed: speed}}
  end
end
