defmodule VmsCore.VwPolo.Abs do
  use GenServer
  alias Decimal, as: D

  require Logger
  alias Cantastic.{Frame, Signal}

  @network_name :polo_drive

  @abs_status_frame_name "abs_status"
  @zero D.new(0)

  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, @abs_status_frame_name)
    {:ok, %{
      speed: @zero
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{signals: signals}}, state) do
    %{"speed" => %Signal{value: speed}} = signals
    {:noreply, %{state | speed: speed}}
  end

  @impl true
  def handle_call(:speed, _from, state) do
    {:reply, {:ok, state.speed}, state}
  end

  def speed() do
    GenServer.call(__MODULE__, :speed)
  end
end
