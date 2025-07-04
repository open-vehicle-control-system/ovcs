defmodule VmsCore.Components.OVCS.ROSControl.Steering do
  @moduledoc """
    Control steering based on ROS control's input
  """
  use GenServer
  alias Cantastic.{Receiver, Frame, Signal}
  alias Decimal, as: D
  alias VmsCore.Bus

  @loop_period 10
  @zero D.new(0)
  @range 2**31 - 1

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, "ros_control1")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      raw_value: 0,
      requested_steering: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_steering()
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "ros_control1", signals: signals}}, state) do
    %{"steering" => %Signal{name: "steering", value: raw_value}} = signals
    {:noreply, %{state | raw_value: raw_value}}
  end

  defp compute_steering(state) do
    requested_steering = state.raw_value |> D.div(@range)
    %{state | requested_steering: requested_steering}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_steering, value: state.requested_steering, source: __MODULE__})
    state
  end
end
