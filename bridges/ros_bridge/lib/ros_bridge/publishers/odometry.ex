defmodule RosBridge.Publishers.Odometry.State do
  @moduledoc false
  defstruct [
    :topic,
    :odom_frame_id,
    :base_frame_id,
    :stale_after_ms,
    :pose_covariance,
    :twist_covariance,
    base_offset: 0.0,
    x: 0.0,
    y: 0.0,
    yaw: nil,
    yaw_offset: nil,
    yaw_rate: 0.0,
    speed: 0.0,
    speed_valid: false,
    distance: nil,
    distance_valid: false,
    steering_angle: 0.0,
    sequence: nil,
    last_fresh_at_ms: nil
  ]
end

defmodule RosBridge.Publishers.Odometry do
  @moduledoc """
  Dead-reckoned odometry: `/odom` (`nav_msgs/Odometry`) and the
  `odom → base_link` transform on `/tf`, from two sources this bridge
  already has —

    * the VMS's `vehicle_motion` frame (`0x60B`): signed speed and the
      commanded steering angle;
    * the IMU driver's rotation vector: the heading.

  Position integrates the distance rolled between two *fresh* frames
  along the IMU heading, `x += Δd·cos(ψ), y += Δd·sin(ψ)` — the frame's
  `sequence` is what distinguishes a new sample from
  `Cantastic.Emitter`'s retransmission of the last one. `Δd` is the
  difference of the frame's distance counter, which carries no
  measuring window's lag; while `distance_valid` is false it falls back
  to `v·dt`. A step longer than the vehicle can roll between two
  samples, a counter that restarted, is skipped.

  Each fresh sample is published at once, stamped with the time it
  arrived.
  The first heading seen becomes the odom frame's zero, so a run
  starts at the origin pointing along +x regardless of where the IMU's
  own zero happens to point.

  ## The rear axle moves along the heading, not base_link

  A car pivots about its rear axle, so that is the point whose velocity
  lies along the heading, and the point integrated. A `base_link` ahead
  of it, midway between the axles say, also slides outward in a turn:
  it is published `:base_ahead_of_rear_axle` along the heading from the
  integrated point, and its twist carries the sideways speed
  `ω · base_ahead_of_rear_axle`.

  ## Not knowing is not standing still

  Publishing stops — no `/odom`, no `/tf` — whenever the estimate is
  not trustworthy: `speed_valid` is false (the VMS lost its own speed),
  no fresh frame has arrived within `:stale_after_ms`, or no rotation
  sample has arrived yet. tf lookups never extrapolate past the newest
  stamp, so a stopped publisher halts Nav2 rather than letting it plan
  against a frozen pose. Integration across a gap is skipped for the
  same reason: the vehicle's path during the outage is unknown, and a
  silent position jump is worse than a pause.

  ## Options

    * `:topic` (`"odom"`), `:odom_frame_id` (`"odom"`),
      `:base_frame_id` (`"base_link"`).
    * `:stale_after_ms` (default 300) — matches the VMS-side
      `Freshness` timeout on the command path.
    * `:base_ahead_of_rear_axle` (default 0.0) — metres from the rear
      axle forward to `base_link`. Zero when `base_link` is on the
      rear axle.
    * `:pose_variance`, `:twist_variance` — the covariance diagonals,
      in the order x, y, z, roll, pitch, yaw. The defaults suit a car
      on flat ground: tight in the plane, and the axes it cannot move
      along declared unknown (large) rather than perfect (0), which is
      how a zero reads.

  The IMU driver must already be running (the `:imu_publisher`
  component starts it); this registers as a second listener on it.
  """
  use GenServer

  alias Cantastic.{Frame, Receiver, Signal}
  alias OvcsDrivers.Imu.Sample

  alias Ros2.GeometryMsgs.Msg.{
    Point,
    Pose,
    PoseWithCovariance,
    Quaternion,
    Transform,
    TransformStamped,
    Twist,
    TwistWithCovariance,
    Vector3
  }

  alias Ros2.NavMsgs.Msg.Odometry
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.Tf2Msgs.Msg.TFMessage
  alias RosBridge.Publishers.Odometry.State
  alias RosBridge.Timing

  require Logger

  @frame_name "vehicle_motion"
  @default_topic "odom"
  @default_stale_after_ms 300
  # A longer interval means the stream was interrupted; the path across
  # the gap is unknown, so the step is dropped rather than integrated.
  @max_step_s 0.5
  # The frame's distance signal is 16 bits unsigned at 1 mm per count.
  @distance_wrap_m 65.536
  # A larger step is a restarted counter, not distance rolled.
  @max_distance_step_m 0.5

  @default_pose_variance [1.0e-4, 1.0e-4, 1.0e6, 1.0e6, 1.0e6, 3.0e-4]
  # No slip: the only sideways speed is the turn's, ω · base_offset.
  @default_twist_variance [4.0e-4, 1.0e-6, 1.0e6, 1.0e6, 1.0e6, 1.0e-4]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)
    base_offset = Keyword.get(opts, :base_ahead_of_rear_axle, 0.0) * 1.0

    state = %State{
      # The integrated point is the rear axle; base_link starts at the origin.
      base_offset: base_offset,
      x: -base_offset,
      topic: Keyword.get(opts, :topic, @default_topic),
      odom_frame_id: Keyword.get(opts, :odom_frame_id, "odom"),
      base_frame_id: Keyword.get(opts, :base_frame_id, "base_link"),
      stale_after_ms: Keyword.get(opts, :stale_after_ms, @default_stale_after_ms),
      pose_covariance: diagonal(Keyword.get(opts, :pose_variance, @default_pose_variance)),
      twist_covariance: diagonal(Keyword.get(opts, :twist_variance, @default_twist_variance))
    }

    :ok = Receiver.subscribe(self(), :ovcs, @frame_name)
    driver.register_listener(self())

    Logger.info(
      "#{__MODULE__} publishing Ros2.NavMsgs.Msg.Odometry on #{state.topic} " <>
        "and #{state.odom_frame_id} -> #{state.base_frame_id} on tf"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:handle_frame, %Frame{name: @frame_name, signals: signals}}, state) do
    %{
      "speed" => %Signal{value: speed},
      "steering_angle" => %Signal{value: steering_angle},
      "speed_valid" => %Signal{value: speed_valid},
      "distance" => %Signal{value: distance},
      "distance_valid" => %Signal{value: distance_valid},
      "sequence" => %Signal{value: sequence}
    } = signals

    received_at_ms = now_ms()

    next_state =
      observe(state, %{
        speed: Decimal.to_float(speed),
        steering_angle: Decimal.to_float(steering_angle),
        # Anything but true, a value the frame layout does not map
        # included, leaves the reading unusable.
        speed_valid: speed_valid == true,
        distance: Decimal.to_float(distance),
        distance_valid: distance_valid == true,
        sequence: sequence,
        at_ms: received_at_ms
      })

    if next_state.sequence != state.sequence and publishable?(next_state, received_at_ms),
      do: publish(next_state)

    {:noreply, next_state}
  end

  # Anything else is ignored rather than fatal: a gap in odometry is
  # recoverable, a crashed publisher restarts the whole bridge subtree.
  def handle_info(_message, state), do: {:noreply, state}

  # IMU drivers deliver samples as casts — see `OvcsDrivers.Imu`.
  @impl GenServer
  def handle_cast({:imu_sample, %Sample{kind: :rotation, x: x, y: y, z: z, w: w}}, state) do
    yaw = yaw_from_quaternion(x, y, z, w)
    yaw_offset = state.yaw_offset || yaw
    {:noreply, %{state | yaw: yaw - yaw_offset, yaw_offset: yaw_offset}}
  end

  def handle_cast({:imu_sample, %Sample{kind: :angular_velocity, z: yaw_rate}}, state) do
    {:noreply, %{state | yaw_rate: yaw_rate}}
  end

  def handle_cast({:imu_sample, %Sample{}}, state), do: {:noreply, state}

  @doc """
  The state after a `vehicle_motion` sample. A retransmission (same
  sequence) changes nothing. A fresh sample integrates the distance
  covered since the previous fresh sample along the current heading,
  unless the gap is too wide to trust or the estimate is not valid.
  """
  def observe(%State{sequence: sequence} = state, %{sequence: sequence}), do: state

  def observe(%State{} = state, sample) do
    elapsed_s = step_seconds(state.last_fresh_at_ms, sample.at_ms)

    step_m = if integrable?(state, sample, elapsed_s), do: step_metres(state, sample, elapsed_s)

    state =
      if step_m do
        %{
          state
          | x: state.x + step_m * :math.cos(state.yaw),
            y: state.y + step_m * :math.sin(state.yaw)
        }
      else
        state
      end

    %{
      state
      | speed: sample.speed,
        steering_angle: sample.steering_angle,
        speed_valid: sample.speed_valid,
        distance: Map.get(sample, :distance),
        distance_valid: Map.get(sample, :distance_valid, false),
        sequence: sample.sequence,
        last_fresh_at_ms: sample.at_ms
    }
  end

  # Counter difference, else speed over the interval; nil for an implausible jump.
  defp step_metres(
         %State{distance_valid: true, distance: previous_distance_m},
         %{distance_valid: true, distance: distance_m},
         _elapsed_s
       )
       when is_float(previous_distance_m) and is_float(distance_m) do
    step_m = unwrap_distance_step(distance_m - previous_distance_m)
    if abs(step_m) <= @max_distance_step_m, do: step_m
  end

  defp step_metres(state, _sample, elapsed_s), do: state.speed * elapsed_s

  defp unwrap_distance_step(delta_m) do
    half_wrap_m = @distance_wrap_m / 2
    delta_m - @distance_wrap_m * Float.floor((delta_m + half_wrap_m) / @distance_wrap_m)
  end

  defp step_seconds(nil, _now_ms), do: nil
  defp step_seconds(last_ms, now_ms), do: (now_ms - last_ms) / 1000

  defp integrable?(state, sample, elapsed_s) do
    state.speed_valid and sample.speed_valid and not is_nil(state.yaw) and
      not is_nil(elapsed_s) and elapsed_s <= @max_step_s
  end

  @doc false
  def publishable?(%State{} = state, now_ms) do
    state.speed_valid and not is_nil(state.yaw) and not is_nil(state.last_fresh_at_ms) and
      now_ms - state.last_fresh_at_ms <= state.stale_after_ms
  end

  @doc """
  The yaw of a quaternion. Planar odometry: the pose's orientation
  carries the yaw alone, as a rotation about z; roll and pitch are left
  to the IMU publisher.
  """
  def yaw_from_quaternion(x, y, z, w) do
    :math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))
  end

  @doc false
  def base_position(%State{} = state) do
    {state.x + state.base_offset * :math.cos(state.yaw),
     state.y + state.base_offset * :math.sin(state.yaw)}
  end

  @doc "Row-major 6x6 covariance with `variances` on the diagonal."
  def diagonal([_, _, _, _, _, _] = variances) do
    for row <- 0..5,
        column <- 0..5,
        do: if(row == column, do: Enum.at(variances, row) * 1.0, else: 0.0)
  end

  defp publish(%State{} = state) do
    stamp = Timing.stamp_from_monotonic(System.monotonic_time(:nanosecond))
    {x, y} = base_position(state)

    orientation = %Quaternion{
      x: 0.0,
      y: 0.0,
      z: :math.sin(state.yaw / 2),
      w: :math.cos(state.yaw / 2)
    }

    odometry = %Odometry{
      header: %Header{stamp: stamp, frame_id: state.odom_frame_id},
      child_frame_id: state.base_frame_id,
      pose: %PoseWithCovariance{
        pose: %Pose{
          position: %Point{x: x, y: y, z: 0.0},
          orientation: orientation
        },
        covariance: state.pose_covariance
      },
      twist: %TwistWithCovariance{
        twist: %Twist{
          linear: %Vector3{x: state.speed, y: state.yaw_rate * state.base_offset, z: 0.0},
          angular: %Vector3{x: 0.0, y: 0.0, z: state.yaw_rate}
        },
        covariance: state.twist_covariance
      }
    }

    transform = %TransformStamped{
      header: %Header{stamp: stamp, frame_id: state.odom_frame_id},
      child_frame_id: state.base_frame_id,
      transform: %Transform{
        translation: %Vector3{x: x, y: y, z: 0.0},
        rotation: orientation
      }
    }

    RosBridge.ZenohClient.publish(state.topic, Odometry, odometry)
    RosBridge.ZenohClient.publish("tf", TFMessage, %TFMessage{transforms: [transform]})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
