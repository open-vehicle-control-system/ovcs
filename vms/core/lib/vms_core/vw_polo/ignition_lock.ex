defmodule VmsCore.VwPolo.IgnitionLock do
  use GenServer
  alias Cantastic.{Frame, Signal}

  @loop_period 10

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Cantastic.Receiver.subscribe(self(), :polo_drive, "key_status")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      contact: :off,
      loop_timer: timer
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    VmsCore.Bus.broadcast("messages", %VmsCore.Bus.Message{name: :contact, value: state.contact, source: __MODULE__})
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{"key_state" => %Signal{value: key_status}} = signals
    contact = case key_status do
      "contact_off" -> :off
      "key_engaged" -> :off
      "contact_on"  -> :on
      "start_engine" -> :start
    end
    {:noreply, %{state | contact: contact}}
  end
end
