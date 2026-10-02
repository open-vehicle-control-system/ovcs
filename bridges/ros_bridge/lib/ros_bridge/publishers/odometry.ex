defmodule RosBridge.Publishers.Odometry.State do
  @moduledoc false
  defstruct [
    :topic,
    :odom_frame_id,
    :base_frame_id,
    :publish_interval_ms,
    :stale_after_ms,
    :pose_covariance,
    :twist_covariance,
    base_offset_x: 0.0,
    x: 0.0,
    y: 0.0,
    yaw: nil,
    yaw_offset: nil,
    yaw_rate: 0.0,
    speed: 0.0,
    speed_valid: false,
    steering_angle: 0.0,
    sequence: nil,
    last_fresh_at_ms: nil,
    last_rotation_at_ms: nil,
    last_gyro_at_ms: nil
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

  Position integrates speed along the IMU heading,
  `x += v·cos(ψ)·dt, y += v·sin(ψ)·dt`, with `dt` measured between
  *fresh* frames — the frame's `sequence` is what distinguishes a new
  sample from `Cantastic.Emitter`'s retransmission of the last one.
  The first heading seen becomes the odom frame's zero, so a run
  starts with its rear axle at the origin pointing along +x regardless of where the IMU's
  own zero happens to point.

  ## Not knowing is not standing still

  Publishing stops — no `/odom`, no `/tf` — whenever the estimate is
  not trustworthy: `speed_valid` is false (the VMS lost its own speed),
  a motion frame, heading or gyro sample is older than `:stale_after_ms`.
  Consumers must check timestamps: a latest-TF lookup can return an old
  transform. Integration across a gap is skipped because motion during
  the outage is unknown.

  ## Options

    * `:topic` (`"odom"`), `:odom_frame_id` (`"odom"`),
      `:base_frame_id` (`"base_link"`).
    * `:publish_interval_ms` (default 50) — Nav2's controller runs at
      20 Hz; publishing faster only buffers.
    * `:stale_after_ms` (default 300) — matches the VMS-side
      `Freshness` timeout on the command path.
    * `:base_offset_x` (default 0) — base frame's forward offset from
      the rear axle, in metres. Position integrates at the rear axle;
      the published pose and twist include this lever arm.
    * `:pose_variance`, `:twist_variance` — the covariance diagonals,
      in the order x, y, z, roll, pitch, yaw. The defaults suit a car
      on flat ground: a few centimetres and about a degree in the
      plane, and the axes it cannot move along declared unknown
      (1e6) rather than perfect (0), which is how a zero reads.

  The IMU driver must already be running (the `:imu_publisher`
  component starts it); this registers as a second listener on it.
  """
  use GenServer

  alias Cantastic.{Frame, Receiver, Signal}
  alias OvcsDrivers.Imu.Sample
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, PoseWithCovariance, Quaternion}
  alias Ros2.GeometryMsgs.Msg.{Transform, TransformStamped, Twist, TwistWithCovariance, Vector3}
  alias Ros2.NavMsgs.Msg.Odometry
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.Tf2Msgs.Msg.TFMessage
  alias RosBridge.Publishers.Odometry.State
  alias RosBridge.Timing

  require Logger

  @frame_name "vehicle_motion"
  @default_topic "odom"
  @default_publish_interval_ms 50
  @default_stale_after_ms 300
  # A dt above this means the stream was interrupted; the path across
  # the gap is unknown, so the step is dropped rather than integrated.
  @max_step_s 0.5

  @default_pose_variance [1.0e-4, 1.0e-4, 1.0e6, 1.0e6, 1.0e6, 3.0e-4]
  @default_twist_variance [4.0e-4, 4.0e-4, 1.0e6, 1.0e6, 1.0e6, 1.0e-4]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)

    state = %State{
      topic: Keyword.get(opts, :topic, @default_topic),
      odom_frame_id: Keyword.get(opts, :odom_frame_id, "odom"),
      base_frame_id: Keyword.get(opts, :base_frame_id, "base_link"),
      publish_interval_ms: Keyword.get(opts, :publish_interval_ms, @default_publish_interval_ms),
      stale_after_ms: Keyword.get(opts, :stale_after_ms, @default_stale_after_ms),
      base_offset_x: Keyword.get(opts, :base_offset_x, 0.0),
      pose_covariance: diagonal(Keyword.get(opts, :pose_variance, @default_pose_variance)),
      twist_covariance: diagonal(Keyword.get(opts, :twist_variance, @default_twist_variance))
    }

    :ok = Receiver.subscribe(self(), :ovcs, @frame_name)
    driver.register_listener(self())
    Process.send_after(self(), :tick, state.publish_interval_ms)

    Logger.info(
      "#{__MODULE__} publishing Ros2.NavMsgs.Msg.Odometry on #{state.topic} " <>
        "and #{state.odom_frame_id} -> #{state.base_frame_id} on tf " <>
        "every #{state.publish_interval_ms}ms"
    )

    {:ok, state}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @frame_name, signals: signals}}, state) do
    %{
      "speed" => %Signal{value: speed},
      "steering_angle" => %Signal{value: steering_angle},
      "speed_valid" => %Signal{value: speed_valid},
      "sequence" => %Signal{value: sequence}
    } = signals

    {:noreply,
     observe(state, %{
       speed: Decimal.to_float(speed),
       steering_angle: Decimal.to_float(steering_angle),
       speed_valid: speed_valid,
       sequence: sequence,
       at_ms: now_ms()
     })}
  end

  def handle_info(:tick, %State{} = state) do
    if publishable?(state, now_ms()) do
      publish(state)
    end

    Process.send_after(self(), :tick, state.publish_interval_ms)
    {:noreply, state}
  end

  # Anything else is ignored rather than fatal: a gap in odometry is
  # recoverable, a crashed publisher restarts the whole bridge subtree.
  def handle_info(_message, state), do: {:noreply, state}

  # IMU drivers deliver samples as casts — see `OvcsDrivers.Imu`.
  @impl true
  def handle_cast({:imu_sample, %Sample{kind: :rotation, x: x, y: y, z: z, w: w}}, state) do
    yaw = yaw_from_quaternion(x, y, z, w)
    yaw_offset = state.yaw_offset || yaw

    {:noreply,
     %{state | yaw: yaw - yaw_offset, yaw_offset: yaw_offset, last_rotation_at_ms: now_ms()}}
  end

  def handle_cast({:imu_sample, %Sample{kind: :angular_velocity, z: z}}, state) do
    {:noreply, %{state | yaw_rate: z, last_gyro_at_ms: now_ms()}}
  end

  def handle_cast({:imu_sample, %Sample{}}, state), do: {:noreply, state}

  # A retransmission (same sequence) refreshes nothing and moves
  # nothing. A fresh sample integrates the distance covered since the
  # previous fresh sample along the current heading — unless the gap is
  # too wide to trust or the estimate is not currently valid.
  @doc false
  def observe(%State{sequence: sequence} = state, %{sequence: sequence}), do: state

  def observe(%State{} = state, sample) do
    dt_s = step_seconds(state.last_fresh_at_ms, sample.at_ms)

    state =
      if integrable?(state, sample, dt_s) do
        %{
          state
          | x: state.x + state.speed * :math.cos(state.yaw) * dt_s,
            y: state.y + state.speed * :math.sin(state.yaw) * dt_s
        }
      else
        state
      end

    %{
      state
      | speed: sample.speed,
        steering_angle: sample.steering_angle,
        speed_valid: sample.speed_valid,
        sequence: sample.sequence,
        last_fresh_at_ms: sample.at_ms
    }
  end

  defp step_seconds(nil, _now_ms), do: nil
  defp step_seconds(last_ms, now_ms), do: (now_ms - last_ms) / 1000

  defp integrable?(state, sample, dt_s) do
    state.speed_valid and sample.speed_valid and not is_nil(state.yaw) and
      not is_nil(dt_s) and dt_s > 0 and dt_s <= @max_step_s and
      imu_fresh?(state, sample.at_ms)
  end

  @doc false
  def publishable?(%State{} = state, now_ms) do
    state.speed_valid and not is_nil(state.yaw) and not is_nil(state.last_fresh_at_ms) and
      fresh?(state.last_fresh_at_ms, now_ms, state.stale_after_ms) and imu_fresh?(state, now_ms)
  end

  defp imu_fresh?(state, now_ms) do
    fresh?(state.last_rotation_at_ms, now_ms, state.stale_after_ms) and
      fresh?(state.last_gyro_at_ms, now_ms, state.stale_after_ms)
  end

  defp fresh?(nil, _now_ms, _timeout), do: false
  defp fresh?(at_ms, now_ms, timeout), do: (now_ms - at_ms) in 0..timeout

  @doc false
  def base_position(%State{} = state) do
    {state.x + state.base_offset_x * :math.cos(state.yaw),
     state.y + state.base_offset_x * :math.sin(state.yaw)}
  end

  # Planar odometry: the pose's orientation carries the yaw alone, as a
  # rotation about z. Roll and pitch are the IMU publisher's story.
  @doc false
  def yaw_from_quaternion(x, y, z, w) do
    :math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))
  end

  @doc false
  # Row-major 6x6 with the variances on the diagonal.
  def diagonal([_, _, _, _, _, _] = variances) do
    for row <- 0..5, col <- 0..5, do: if(row == col, do: Enum.at(variances, row) * 1.0, else: 0.0)
  end

  defp publish(%State{} = state) do
    {x, y} = base_position(state)
    stamp = Timing.time_message_for(state.last_fresh_at_ms * 1_000_000)

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
          linear: %Vector3{x: state.speed, y: state.base_offset_x * state.yaw_rate, z: 0.0},
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
