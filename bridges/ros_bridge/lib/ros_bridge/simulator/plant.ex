defmodule RosBridge.Simulator.Plant do
  @moduledoc """
  Stands in for a vehicle's hardware against a simulator, so the VMS
  drives the simulated vehicle over CAN as it drives the real one.
  **Simulation only.**

  Every tick it collects the actuations of the vehicle's simulated
  components (`RosBridge.Simulator.SimulatedComponent`), advances
  `RosBridge.Simulator.Vehicle`, lets each report the motion as the
  hardware it stands in for would, and
  publishes the vehicle's speed and Ackermann yaw rate to the simulator
  as a `geometry_msgs/Twist` on `:drive_topic`. The simulator's own
  drive plugin moves the vehicle; the VMS learns how far it went only
  from the simulated components' telemetry.

  The telemetry measures the simulated wheels, as the vehicle's motor
  and shaft sensors do. How far they turned is the `:wheel_joints`'
  mean position on `joint_states`, which the simulator integrates, and
  how fast is that distance per second of the plant's clock, the wall
  clock the VMS measures against (see `RosBridge.Simulator.Vehicle`): the counters match the simulator, and
  the rates match the counters, however fast the simulator runs. The
  positions are cumulative, so samples arriving late or in bursts lose
  nothing. Before the first one, or without `:wheel_joints`, the plant
  reports its own commanded motion instead.

  ## Options

    * `:vehicle` (required) — `RosBridge.Simulator.Vehicle.new/1`'s
      parameters.
    * `:simulated_components` (required) — `{module, opts}` per
      simulated component.
    * `:drive_topic` (`"simulator/drive"`).
    * `:wheel_joints` (`[]`) — the joints the drive turns, each positive
      when rolling forward; none for no measurement.

  The bridge firmware's CAN topology must declare every frame the
  simulated components read and emit, the other way round from the VMS's.
  """
  use GenServer

  alias Cantastic.{Emitter, Frame, Receiver}
  alias Ros2.GeometryMsgs.Msg.{Twist, Vector3}
  alias Ros2.SensorMsgs.Msg.JointState
  alias RosBridge.Simulator.Vehicle

  require Logger

  @loop_period_ms 10
  @drive_period_ms 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    opts = Map.new(opts)

    components =
      opts
      |> Map.fetch!(:simulated_components)
      |> Enum.map(fn {module, component_opts} ->
        {state, received, emitted} = module.init(component_opts)
        :ok = subscribe(received)
        :ok = configure_emitters(emitted)
        %{module: module, state: state, received: MapSet.new(received)}
      end)

    wheel_joints = Map.get(opts, :wheel_joints, [])

    if wheel_joints != [], do: :ok = RosBridge.ZenohClient.subscribe("joint_states", JointState)

    {:ok, _timer} = :timer.send_interval(@loop_period_ms, :loop)

    Logger.info(
      "#{__MODULE__}: emulating #{Enum.map_join(components, ", ", &inspect(&1.module))}"
    )

    {:ok,
     %{
       vehicle: Vehicle.new(Map.fetch!(opts, :vehicle)),
       components: components,
       drive_topic: Map.get(opts, :drive_topic, "simulator/drive"),
       last_step_ms: now_ms(),
       last_drive_ms: now_ms() - @drive_period_ms,
       wheel_joints: wheel_joints,
       wheel_turns: nil,
       wheel_turns_read: nil
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    now_ms = now_ms()

    dt_s = (now_ms - state.last_step_ms) / 1000
    actuations = Enum.flat_map(state.components, &actuations(&1, state.vehicle, now_ms))
    vehicle = Vehicle.step(state.vehicle, actuations, dt_s, wheel_turns_step(state))
    components = Enum.map(state.components, &step(&1, vehicle, dt_s, now_ms))

    state = %{
      state
      | vehicle: vehicle,
        components: components,
        last_step_ms: now_ms,
        wheel_turns_read: state.wheel_turns
    }

    {:noreply, publish_drive(state, now_ms)}
  end

  def handle_info(
        {:handle_frame, %Frame{network_name: network, name: name, signals: signals}},
        state
      ) do
    components =
      Enum.map(state.components, fn component ->
        if MapSet.member?(component.received, {network, name}),
          do: %{
            component
            | state: component.module.handle_frame(name, signals, component.state, now_ms())
          },
          else: component
      end)

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

  defp actuations(component, vehicle, now_ms) do
    if function_exported?(component.module, :actuations, 3),
      do: component.module.actuations(component.state, vehicle, now_ms),
      else: []
  end

  defp step(component, vehicle, dt_s, now_ms) do
    {state, updates} = component.module.step(component.state, vehicle, dt_s, now_ms)

    Enum.each(updates, fn {network, frame_name, signals} ->
      :ok = Emitter.update(network, frame_name, &Map.merge(&1, signals))
    end)

    %{component | state: state}
  end

  defp publish_drive(state, now_ms) when now_ms - state.last_drive_ms < @drive_period_ms,
    do: state

  defp publish_drive(state, now_ms) do
    twist = %Twist{
      linear: %Vector3{x: state.vehicle.speed_m_s, y: 0.0, z: 0.0},
      angular: %Vector3{x: 0.0, y: 0.0, z: Vehicle.yaw_rate(state.vehicle)}
    }

    RosBridge.ZenohClient.publish(state.drive_topic, Twist, twist)
    %{state | last_drive_ms: now_ms}
  end

  defp subscribe(received) do
    received
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {network, frame_names} ->
      :ok = Receiver.subscribe(self(), network, frame_names)
    end)
  end

  defp configure_emitters(emitted) do
    Enum.each(emitted, fn {network, frame_name, initial_data} ->
      :ok =
        Emitter.configure(network, frame_name, %{
          parameters_builder_function: :default,
          initial_data: initial_data,
          enable: true
        })
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
