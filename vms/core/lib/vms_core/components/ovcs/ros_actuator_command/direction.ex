defmodule VmsCore.Components.OVCS.RosActuatorCommand.Direction do
  @moduledoc """
  Direction from the ROS bridge's actuator command (`ros_actuator_command`,
  `0x2B0`). Carried as its own signal because on OVCS1 a negative
  throttle is regenerative braking, not reverse: reverse is a gear, and
  this is what asks for it. Holds when the input goes stale; direction
  is inert once the throttle has been zeroed.
  """
  use GenServer
  alias Cantastic.{Receiver, Frame, Signal}
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.RosCommand.Freshness

  @frame_name "ros_actuator_command"
  @loop_period 10
  @timeout_ms 500
  @value_mapping %{"forward" => :forward, "backward" => :backward}

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
       requested_direction: :forward
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    {_transition, freshness} = Freshness.check(state.freshness, now())
    {:noreply, emit(%{state | freshness: freshness})}
  end

  def handle_info({:handle_frame, %Frame{name: @frame_name, signals: signals}}, state) do
    %{"direction" => %Signal{value: direction}, "sequence" => %Signal{value: sequence}} = signals

    case Freshness.observe(state.freshness, sequence, now()) do
      {:new, freshness} ->
        {:noreply,
         %{state | freshness: freshness, requested_direction: @value_mapping[direction]}}

      {:repeat, freshness} ->
        {:noreply, %{state | freshness: freshness}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_direction,
      value: state.requested_direction,
      source: __MODULE__
    })

    state
  end

  defp now, do: System.monotonic_time(:millisecond)
end
