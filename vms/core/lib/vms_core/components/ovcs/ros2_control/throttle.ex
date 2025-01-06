defmodule VmsCore.Components.OVCS.Ros2Control.Throttle do
  @moduledoc """
    Control throttle based on ros2 control's input
  """
  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias Decimal, as: D
  alias VmsCore.Bus

  @loop_period 10
  @zero D.new(0)
  @min_value 0 # in m/s
  @max_value 4 # in m/s

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    channel_frame_name = "ros2_control"
    :ok = Receiver.subscribe(self(), :ovcs, channel_frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      frame_name: channel_frame_name,
      name: "linear",
      desired_speed: @zero,
      requested_throttle: @zero,
      requested_gear: :drive
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_throttle()
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state) when name == state.frame_name do
    requested_speed = signals[state.name].value
    desired_speed = requested_speed |> D.min(@max_value) |> D.max(@min_value)
    {:noreply, %{state | desired_speed: desired_speed}}
  end

  defp compute_throttle(state) do
    # TODO use a PID for speed
    requested_throttle = 0
    %{state | requested_throttle: requested_throttle}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_gear, value: state.requested_gear, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :requested_throttle, value: state.requested_throttle, source: __MODULE__})
    state
  end
end
