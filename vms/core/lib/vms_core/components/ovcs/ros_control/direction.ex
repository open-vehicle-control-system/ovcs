defmodule VmsCore.Components.OVCS.ROSControl.Direction do
  @moduledoc """
    Direction based on radio control's input
  """

  use GenServer
  alias Cantastic.{Receiver, Frame, Signal}
  alias VmsCore.Bus

  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, "ros_control0")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      direction: "forward"
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "ros_control0", signals: signals}}, state) do
    %{"direction" => %Signal{name: "direction", value: direction}} = signals
    {:noreply, %{state | direction: direction}}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :direction, value: state.direction, source: __MODULE__})
    state
  end
end
