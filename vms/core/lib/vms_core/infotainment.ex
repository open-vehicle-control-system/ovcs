defmodule VmsCore.Infotainment do
  use GenServer

  alias Cantastic.{Receiver, Emitter, Frame, Signal}

  @network_name :ovcs
  @infotainment_status_frame_name "infotainment_status"

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), @network_name, @infotainment_status_frame_name)
    {:ok, %{requested_gear: "parking"}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{"requested_gear" => %Signal{value: requested_gear}} = signals
    {:noreply, %{state | requested_gear: requested_gear}}
  end

  @impl true
  def handle_call(:requested_gear, _from, state) do
    {:reply, {:ok, state.requested_gear}, state}
  end

  def requested_gear() do
    GenServer.call(__MODULE__, :requested_gear)
  end
end
