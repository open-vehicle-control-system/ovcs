defmodule VmsCore.Infotainment do
  use GenServer

  alias Cantastic.{Receiver, Frame, Signal}
  alias VmsCore.Bus

  @loop_period 10

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, "infotainment_status")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      requested_gear: :parking,
      loop_timer: timer
    }}
  end


  @impl true
  def handle_info(:loop, state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_gear, value: state.requested_gear, source: __MODULE__})
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{"requested_gear" => %Signal{value: requested_gear}} = signals
    {:noreply, %{state | requested_gear: String.to_atom(requested_gear)}}
  end
end
