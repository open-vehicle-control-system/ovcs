defmodule RosBridge.Publishers.AckermannJointStates.State do
  @moduledoc false
  defstruct [
    :topic,
    :steering_joints,
    :wheel_joints,
    :wheelbase,
    :kingpin_width,
    :wheel_radius,
    sequence: nil,
    distance: nil,
    steering_angle: 0.0,
    wheel_angle: 0.0
  ]
end

defmodule RosBridge.Publishers.AckermannJointStates do
  @moduledoc """
  An Ackermann vehicle's moving joints on `/joint_states`
  (`sensor_msgs/JointState`), from the VMS's `vehicle_motion` frame
  (`0x60B`), so `robot_state_publisher` places its wheels as the
  vehicle drives: what Gazebo publishes in simulation, where this must
  not run.

    * The two steered wheels turn to the angles of the frame's
      commanded steering, a bicycle-model angle, about pivots
      `:kingpin_width` apart: the inner wheel turns more.
    * Every wheel turns by the distance rolled over `:wheel_radius`,
      from the frame's distance counter. While `distance_valid` is
      false, they hold still.

  Each fresh sample (a new `sequence`) is published at once, stamped
  with the time it arrived.

  ## Options

    * `:steering_joints` (required) — `{left, right}`, the steered
      wheels' joints, positive turning left.
    * `:wheel_joints` (required) — every wheel's joint, positive
      rolling forward.
    * `:wheelbase`, `:kingpin_width`, `:wheel_radius` (required) — in
      metres.
    * `:topic` (`"joint_states"`).
  """
  use GenServer

  alias Cantastic.{Frame, Receiver, Signal}
  alias Ros2.SensorMsgs.Msg.JointState
  alias Ros2.StdMsgs.Msg.Header
  alias RosBridge.Publishers.AckermannJointStates.State
  alias RosBridge.{Timing, VehicleMotion}

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    state = %State{
      topic: Keyword.get(opts, :topic, "joint_states"),
      steering_joints: Keyword.fetch!(opts, :steering_joints),
      wheel_joints: Keyword.fetch!(opts, :wheel_joints),
      wheelbase: Keyword.fetch!(opts, :wheelbase) * 1.0,
      kingpin_width: Keyword.fetch!(opts, :kingpin_width) * 1.0,
      wheel_radius: Keyword.fetch!(opts, :wheel_radius) * 1.0
    }

    :ok = Receiver.subscribe(self(), :ovcs, VehicleMotion.frame_name())
    Logger.info("#{__MODULE__} publishing Ros2.SensorMsgs.Msg.JointState on #{state.topic}")
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:handle_frame, %Frame{name: "vehicle_motion", signals: signals}}, state) do
    %{
      "steering_angle" => %Signal{value: steering_angle},
      "distance" => %Signal{value: distance},
      "distance_valid" => %Signal{value: distance_valid},
      "sequence" => %Signal{value: sequence}
    } = signals

    next_state =
      observe(state, %{
        steering_angle: Decimal.to_float(steering_angle),
        distance: if(distance_valid == true, do: Decimal.to_float(distance)),
        sequence: sequence
      })

    if next_state.sequence != state.sequence, do: publish(next_state)
    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  The state after a `vehicle_motion` sample, `distance` nil while it is
  not valid. A retransmission (same sequence) changes nothing.
  """
  def observe(%State{sequence: sequence} = state, %{sequence: sequence}), do: state

  def observe(%State{} = state, sample) do
    step_m =
      if is_float(state.distance) and is_float(sample.distance),
        do: VehicleMotion.distance_step(state.distance, sample.distance)

    %{
      state
      | sequence: sample.sequence,
        distance: sample.distance,
        steering_angle: sample.steering_angle,
        wheel_angle: state.wheel_angle + (step_m || 0.0) / state.wheel_radius
    }
  end

  @doc """
  `{left, right}` steered wheels' angles for a bicycle-model
  `steering_angle`, about pivots `kingpin_width` apart: both wheels
  turn about the same centre, on the rear axle's line.

      iex> RosBridge.Publishers.AckermannJointStates.wheel_steering_angles(0.0, 0.324, 0.296)
      {0.0, 0.0}
  """
  @spec wheel_steering_angles(float(), float(), float()) :: {float(), float()}
  def wheel_steering_angles(steering_angle, wheelbase, kingpin_width) do
    tangent = :math.tan(steering_angle)
    half_width = kingpin_width / 2

    {:math.atan2(wheelbase * tangent, wheelbase - half_width * tangent),
     :math.atan2(wheelbase * tangent, wheelbase + half_width * tangent)}
  end

  @doc "The `JointState` for `state`, stamped `stamp`."
  def joint_state(%State{} = state, stamp) do
    {left_joint, right_joint} = state.steering_joints

    {left, right} =
      wheel_steering_angles(state.steering_angle, state.wheelbase, state.kingpin_width)

    %JointState{
      header: %Header{stamp: stamp},
      name: [left_joint, right_joint | state.wheel_joints],
      position: [left, right | Enum.map(state.wheel_joints, fn _ -> state.wheel_angle end)]
    }
  end

  defp publish(state) do
    stamp = Timing.stamp_from_monotonic(System.monotonic_time(:nanosecond))
    RosBridge.ZenohClient.publish(state.topic, JointState, joint_state(state, stamp))
  end
end
