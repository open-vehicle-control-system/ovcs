defmodule VmsCore.VwPolo.Abs do
  use GenServer
  alias VmsCore.Bus

  require Logger
  alias Cantastic.{Frame, Signal}

  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), :polo_drive, "abs_status")
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{signals: signals}}, state) do
    %{"speed" => %Signal{value: speed}} = signals
    Bus.broadcast("messages", %Bus.Message{name: :speed, value: speed, source: __MODULE__})
    {:noreply, state}
  end
end
