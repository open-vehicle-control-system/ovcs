defmodule VmsCore.Components.OVCS.ROSControl.Direction do
  @moduledoc """
    Direction based on ROS control's input
  """

  use GenServer
  alias Cantastic.{Receiver, Frame, Signal}
  alias VmsCore.Bus

  @loop_period 10
  @default_value "forward"
  @value_mapping %{"forward" => :forward, "backward" => :backward}
  @default_direction @value_mapping[@default_value]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, "ros_control0")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      requested_direction: @default_direction
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "ros_control0", signals: signals}}, state) do
    %{"direction" => %Signal{name: "direction", value: requested_direction}} = signals
    {:noreply, %{state | requested_direction: @value_mapping[requested_direction]}}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_direction, value: state.requested_direction, source: __MODULE__})
    state
  end
end
