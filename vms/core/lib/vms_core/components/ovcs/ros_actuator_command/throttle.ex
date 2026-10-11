defmodule VmsCore.Components.OVCS.RosActuatorCommand.Throttle do
  @moduledoc """
  Throttle from the ROS bridge's actuator command (`ros_actuator_command`,
  `0x2B0`): the operator's axis in [-1, 1], applied as is and broadcast
  as `:requested_throttle`. A negative value can mean regenerative
  braking, as on the OVCS1 reference vehicle; reverse is the frame's
  `direction`, read by `RosActuatorCommand.Direction`.

  ## The throttle expires; it is not held

  `handle_frame` is the only thing that moves the request and `emit/1`
  runs every loop regardless, so without an expiry a bridge that stops
  talking leaves the last throttle applied for ever. The frame's
  `sequence` is what expires it: the bridge increments it once per ROS
  sample, and `RosCommand.Freshness` zeroes the request when it has not
  changed for `@timeout_ms`. That covers the bridge dying, the CAN link
  being cut, and the joystick going away while the bridge lives, with
  one mechanism, and it needs no edge from a frame watcher, so a stray
  frame after an outage cannot re-poison the request.

  The timeout is sized for a joystick's autorepeat with a network hop
  in between, and matches the ROS bridge's own watchdog on the same
  input.

  ## Only the throttle expires

  `RosActuatorCommand.Steering` holds its last value rather than
  centring. Removing propulsion is what makes the vehicle safe;
  snapping the wheels straight mid-corner at speed is a new hazard
  rather than a mitigation.
  """
  use GenServer
  alias Cantastic.{Receiver, Frame, Signal}
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.RosCommand.Freshness

  require Logger

  @frame_name "ros_actuator_command"
  @loop_period_ms 10
  @timeout_ms 500
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, @frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       loop_timer: timer,
       freshness: Freshness.new(@timeout_ms, now_ms()),
       requested_throttle: @zero
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    {transition, freshness} = Freshness.check(state.freshness, now_ms())

    state =
      %{state | freshness: freshness}
      |> apply_transition(transition)
      |> emit()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: @frame_name, signals: signals}}, state) do
    %{"throttle" => %Signal{value: throttle}, "sequence" => %Signal{value: sequence}} = signals

    case Freshness.observe(state.freshness, sequence, now_ms()) do
      {:new, freshness} ->
        {:noreply, %{state | freshness: freshness, requested_throttle: throttle}}

      {:repeat, freshness} ->
        {:noreply, %{state | freshness: freshness}}
    end
  end

  # Anything else is ignored rather than fatal: a gap in throttle
  # emission is worse than doing nothing.
  def handle_info(_message, state), do: {:noreply, state}

  defp apply_transition(state, :stale) do
    Logger.warning(
      "#{__MODULE__}: #{@frame_name} carries no new sample — throttle zeroed. " <>
        "The ROS bridge is not commanding this vehicle."
    )

    %{state | requested_throttle: @zero}
  end

  defp apply_transition(state, :fresh) do
    Logger.info("#{__MODULE__}: #{@frame_name} is fresh again")
    state
  end

  defp apply_transition(state, :unchanged), do: state

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle,
      value: state.requested_throttle,
      source: __MODULE__
    })

    state
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
