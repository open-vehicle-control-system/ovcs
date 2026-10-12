defmodule RosBridge.Simulator.Plant do
  @moduledoc """
  Stands in for a vehicle's hardware against a simulator, so the VMS
  drives the simulated vehicle over CAN as it drives the real one.
  **Simulation only.**

  Every tick it collects the actuations of the vehicle's devices
  (`RosBridge.Simulator.Device`), advances `RosBridge.Simulator.Vehicle`,
  lets each device report the motion as its real counterpart would, and
  publishes the vehicle's speed and Ackermann yaw rate to the simulator
  as a `geometry_msgs/Twist` on `:drive_topic`. The simulator's own
  drive plugin moves the vehicle; the VMS learns how far it went only
  from the devices' telemetry.

  The telemetry measures the simulated wheels, as the vehicle's motor
  and shaft sensors do: the measured speed, which each step starts from
  and reports, is the `:wheel_joints`' mean velocity on `joint_states`
  times the wheel radius. Without a sample in the last
  `@wheel_speed_stale_ms`, the plant reports its own commanded motion
  instead.

  The vehicle moves in simulator time, as Gazebo's does, through
  `RosBridge.Timing`: with `:simulator_clock` listed before this
  component, a simulator running slower than real time moves the
  plant's vehicle as far as its own. Command timeouts and the rates the
  devices report stay on the wall clock, the VMS's; see "Two clocks" in
  `RosBridge.Simulator.Vehicle`.

  ## Options

    * `:vehicle` (required) — `RosBridge.Simulator.Vehicle.new/1`'s
      parameters.
    * `:devices` (required) — `{module, opts}` per device.
    * `:drive_topic` (`"simulator/drive"`).
    * `:wheel_joints` (`[]`) — the joints the drive turns, each positive
      when rolling forward; none for no measurement.

  The bridge firmware's CAN topology must declare every frame the
  devices read and emit, the other way round from the VMS's.
  """
  use GenServer

  alias Cantastic.{Emitter, Frame, Receiver}
  alias Ros2.GeometryMsgs.Msg.{Twist, Vector3}
  alias Ros2.SensorMsgs.Msg.JointState
  alias RosBridge.Simulator.Vehicle
  alias RosBridge.Timing

  require Logger

  @loop_period_ms 10
  @drive_period_ms 20
  @wheel_speed_stale_ms 200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    opts = Map.new(opts)

    devices =
      opts
      |> Map.fetch!(:devices)
      |> Enum.map(fn {module, device_opts} ->
        {state, received, emitted} = module.init(device_opts)
        :ok = subscribe(received)
        :ok = configure_emitters(emitted)
        %{module: module, state: state, received: MapSet.new(received)}
      end)

    wheel_joints = Map.get(opts, :wheel_joints, [])

    if wheel_joints != [], do: :ok = RosBridge.ZenohClient.subscribe("joint_states", JointState)

    {:ok, _timer} = :timer.send_interval(@loop_period_ms, :loop)
    Logger.info("#{__MODULE__}: emulating #{Enum.map_join(devices, ", ", &inspect(&1.module))}")

    {:ok,
     %{
       vehicle: Vehicle.new(Map.fetch!(opts, :vehicle)),
       devices: devices,
       drive_topic: Map.get(opts, :drive_topic, "simulator/drive"),
       vehicle_time_ns: vehicle_time_ns(),
       last_step_ms: now_ms(),
       last_drive_ms: now_ms() - @drive_period_ms,
       wheel_joints: wheel_joints,
       wheel_speed: nil
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    now_ms = now_ms()

    # Each /clock sample can pull the simulator-time estimate back slightly; time only moves forward.
    vehicle_time_ns = max(vehicle_time_ns(), state.vehicle_time_ns)
    dt_s = (vehicle_time_ns - state.vehicle_time_ns) / 1.0e9
    wall_dt_s = (now_ms - state.last_step_ms) / 1000
    actuations = Enum.flat_map(state.devices, &actuations(&1, state.vehicle, now_ms))

    vehicle =
      Vehicle.step(state.vehicle, actuations, dt_s,
        wall_dt_s: wall_dt_s,
        measured_speed_m_s: measured_speed(state.wheel_speed, now_ms)
      )

    devices = Enum.map(state.devices, &step(&1, vehicle, wall_dt_s, now_ms))

    state = %{
      state
      | vehicle: vehicle,
        devices: devices,
        vehicle_time_ns: vehicle_time_ns,
        last_step_ms: now_ms
    }

    {:noreply, publish_drive(state, now_ms)}
  end

  def handle_info(
        {:handle_frame, %Frame{network_name: network, name: name, signals: signals}},
        state
      ) do
    devices =
      Enum.map(state.devices, fn device ->
        if MapSet.member?(device.received, {network, name}),
          do: %{device | state: device.module.handle_frame(name, signals, device.state, now_ms())},
          else: device
      end)

    {:noreply, %{state | devices: devices}}
  end

  def handle_info({:ros_message, {_key_expr, %JointState{} = joint_state}}, state) do
    case wheel_speed(joint_state, state.wheel_joints, state.vehicle.wheel_radius_m) do
      nil -> {:noreply, state}
      speed -> {:noreply, %{state | wheel_speed: {speed, now_ms()}}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp measured_speed({speed, at_ms}, now_ms) when now_ms - at_ms <= @wheel_speed_stale_ms,
    do: speed

  defp measured_speed(_wheel_speed, _now_ms), do: nil

  @doc "`wheel_joints`' mean velocity times `wheel_radius_m`; nil if one is missing. Pure."
  def wheel_speed(%JointState{name: names, velocity: velocities}, wheel_joints, wheel_radius_m) do
    by_name = Enum.zip(names, velocities) |> Map.new()
    speeds = Enum.map(wheel_joints, &Map.get(by_name, &1))

    if nil in speeds,
      do: nil,
      else: Enum.sum(speeds) / length(speeds) * wheel_radius_m
  end

  defp actuations(device, vehicle, now_ms) do
    if function_exported?(device.module, :actuations, 3),
      do: device.module.actuations(device.state, vehicle, now_ms),
      else: []
  end

  defp step(device, vehicle, dt_s, now_ms) do
    {state, updates} = device.module.step(device.state, vehicle, dt_s, now_ms)

    Enum.each(updates, fn {network, frame_name, signals} ->
      :ok = Emitter.update(network, frame_name, &Map.merge(&1, signals))
    end)

    %{device | state: state}
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

  defp vehicle_time_ns, do: Timing.ros_time_of(System.monotonic_time(:nanosecond))
end
