defmodule VmsCore.Components.OVCS.RosActuatorCommand.Steering do
  @moduledoc """
  Steering from the ROS bridge's actuator command (`ros_actuator_command`,
  `0x2B0`): the operator's axis in [-1, 1], applied as is.

  Holds its last value when the input goes stale; see
  `RosActuatorCommand.Throttle` for why only propulsion expires. A
  retransmitted frame, one whose `sequence` has not changed, is not
  applied as fresh input.
  """
  use GenServer
  alias Cantastic.{Receiver, Frame, Signal}
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.RosCommand.Freshness

  @frame_name "ros_actuator_command"
  @loop_period 10
  @timeout_ms 500
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, @frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       freshness: Freshness.new(@timeout_ms, now()),
       requested_steering: @zero
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    {_transition, freshness} = Freshness.check(state.freshness, now())
    {:noreply, emit(%{state | freshness: freshness})}
  end

  def handle_info({:handle_frame, %Frame{name: @frame_name, signals: signals}}, state) do
    %{"steering" => %Signal{value: steering}, "sequence" => %Signal{value: sequence}} = signals

    case Freshness.observe(state.freshness, sequence, now()) do
      {:new, freshness} ->
        {:noreply, %{state | freshness: freshness, requested_steering: steering}}

      {:repeat, freshness} ->
        {:noreply, %{state | freshness: freshness}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_steering,
      value: state.requested_steering,
      source: __MODULE__
    })

    state
  end

  defp now, do: System.monotonic_time(:millisecond)
end
