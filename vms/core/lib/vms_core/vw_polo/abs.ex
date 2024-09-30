defmodule VmsCore.VwPolo.Abs do
  use GenServer
  alias Decimal, as: D
  alias VmsCore.PubSub

  require Logger
  alias Cantastic.{Frame, Signal}
  @zero D.new(0)

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
    PubSub.broadcast("metrics", %PubSub.MetricMessage{name: :speed, value: speed, source: __MODULE__})
    {:noreply, state}
  end
end
