defmodule RosBridge.Simulator.Hardware do
  @moduledoc """
  Stands in for a vehicle's hardware against a simulator, so the VMS
  drives the simulated vehicle over CAN as it drives the real one.
  **Simulation only.**

  Every `@period_ms` it collects the actuations of the vehicle's
  simulated components (`RosBridge.Simulator.SimulatedComponent`),
  advances `RosBridge.Simulator.Vehicle`, lets each report the motion as
  the hardware it stands in for would, and publishes the vehicle's speed
  and Ackermann yaw rate to the simulator as a `geometry_msgs/Twist` on
  `simulator/drive`. The simulator's own drive plugin moves the vehicle;
  the VMS learns how far it went only from the simulated components'
  telemetry.

  The telemetry measures the simulated wheels, as the vehicle's motor
  and shaft sensors do. How far they turned is the `:wheel_joints`'
  mean position on `joint_states`, which the simulator integrates, and
  how fast is that distance per second of the wall clock the VMS
  measures against (see `RosBridge.Simulator.Vehicle`): the counters
  match the simulator, and the rates match the counters, however fast
  the simulator runs. The positions are cumulative, so samples arriving
  late or in bursts lose nothing. Before the first one, or without
  `:wheel_joints`, it reports its own commanded motion instead.

  ## Options

    * `:vehicle` (required) — `RosBridge.Simulator.Vehicle.new/1`'s
      parameters.
    * `:simulated_components` (required) — `{module, opts}` per
      simulated component.
    * `:wheel_joints` (`[]`) — the joints the drive turns, each positive
      when rolling forward; none for no measurement.

  The bridge firmware's CAN topology must declare every frame the
  simulated components read and emit, the other way round from the VMS's.
  """
  use GenServer

  alias Cantastic.Frame
  alias Ros2.GeometryMsgs.Msg.{Twist, Vector3}
  alias Ros2.SensorMsgs.Msg.JointState
  alias RosBridge.Simulator.{SimulatedComponent, Vehicle}

  require Logger

  @period_ms 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    opts = Map.new(opts)

    components =
      opts |> Map.fetch!(:simulated_components) |> Enum.map(&SimulatedComponent.start/1)

    wheel_joints = Map.get(opts, :wheel_joints, [])
    if wheel_joints != [], do: :ok = RosBridge.ZenohClient.subscribe("joint_states", JointState)

    {:ok, _timer} = :timer.send_interval(@period_ms, :step)

    Logger.info(
      "#{__MODULE__}: emulating #{Enum.map_join(components, ", ", &inspect(&1.module))}"
    )

    {:ok,
     %{
       vehicle: Vehicle.new(Map.fetch!(opts, :vehicle)),
       components: components,
       last_step_ms: now_ms(),
       wheel_joints: wheel_joints,
       wheel_turns: nil,
       wheel_turns_read: nil
     }}
  end

  @impl GenServer
  def handle_info(:step, state) do
    now_ms = now_ms()
    dt_s = (now_ms - state.last_step_ms) / 1000

    actuations =
      Enum.flat_map(state.components, &SimulatedComponent.actuations(&1, state.vehicle, now_ms))

    vehicle = Vehicle.step(state.vehicle, actuations, dt_s, wheel_turns_step(state))
    components = Enum.map(state.components, &SimulatedComponent.step(&1, vehicle, dt_s, now_ms))
    publish_drive(vehicle)

    {:noreply,
     %{
       state
       | vehicle: vehicle,
         components: components,
         last_step_ms: now_ms,
         wheel_turns_read: state.wheel_turns
     }}
  end

  def handle_info({:handle_frame, %Frame{} = frame}, state) do
    components = Enum.map(state.components, &SimulatedComponent.handle_frame(&1, frame, now_ms()))
    {:noreply, %{state | components: components}}
  end

  def handle_info({:ros_message, {_key_expr, %JointState{} = joint_state}}, state) do
    case wheel_turns(joint_state, state.wheel_joints) do
      nil -> {:noreply, state}
      turns -> {:noreply, %{state | wheel_turns: turns}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp wheel_turns_step(%{wheel_turns: nil}), do: nil

  defp wheel_turns_step(state),
    do: state.wheel_turns - (state.wheel_turns_read || state.wheel_turns)

  @doc "`wheel_joints`' mean position in `joint_state`, in turns; nil if one is missing. Pure."
  def wheel_turns(%JointState{name: names, position: positions}, wheel_joints) do
    by_name = Enum.zip(names, positions) |> Map.new()
    radians = Enum.map(wheel_joints, &Map.get(by_name, &1))

    if nil in radians,
      do: nil,
      else: Enum.sum(radians) / length(radians) / (2 * :math.pi())
  end

  defp publish_drive(vehicle) do
    twist = %Twist{
      linear: %Vector3{x: vehicle.speed_m_s, y: 0.0, z: 0.0},
      angular: %Vector3{x: 0.0, y: 0.0, z: Vehicle.yaw_rate(vehicle)}
    }

    RosBridge.ZenohClient.publish("simulator/drive", Twist, twist)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
