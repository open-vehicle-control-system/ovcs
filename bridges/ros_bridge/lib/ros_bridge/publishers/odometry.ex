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
    tf_frame_id: nil,
    tf_base_offset: nil,
    imu_mount: {0.0, 0.0, 0.0, 1.0},
    imu_stale_after_ms: 200,
    minimum_imu_accuracy: 0,
    imu_reference: nil,
    imu_reset: false,
    yaw_at_ms: nil,
    yaw_rate_at_ms: nil,
    last_step_yaw: nil,
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
  along the constant-curvature arc between successive IMU headings.
  Heading differences wrap at ±π. The frame's
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
  or angular-velocity sample is fresh. Each IMU stream expires separately.
  A changed IMU orientation reference latches publication off until this
  publisher is restarted with navigation stopped; a sensor reset cannot
  silently rotate an existing odometry frame. tf lookups never extrapolate past the newest
  stamp, so a stopped publisher halts Nav2 rather than letting it plan
  against a frozen pose. Integration across a gap is skipped for the
  same reason: the vehicle's path during the outage is unknown, and a
  silent position jump is worse than a pause.

  ## Range readings wait for odometry

  `RosBridge.Publishers.Range` publishes a reading only while
  `publishing?/1` holds. Nav2's `RangeSensorLayer` waits on each reading
  it cannot place in `odom` until its transform tolerance runs out; a
  stream of readings across a gap in `odom → base_link`, a VMS reboot
  say, leaves it further behind with every reading and its costmaps stop
  publishing. Laser scans go through Nav2's message filters, which drop
  what they cannot place, and are not held back.

  ## Options

    * `:topic` (`"odom"`), `:odom_frame_id` (`"odom"`),
      `:base_frame_id` (`"base_link"`).
    * `:stale_after_ms` (default 300) — matches the VMS-side
      `Freshness` timeout on the command path.
    * `:base_ahead_of_rear_axle` (default 0.0) — metres from the rear
      axle forward to `base_link`. Zero when `base_link` is on the
      rear axle.
    * `:tf_frame_id`, `:tf_ahead_of_rear_axle` — optionally publish TF
      for another rigidly attached frame while odometry describes
      `:base_frame_id`. Defaults to that frame and its axle offset.
      The URDF must supply the fixed relationship between them.
    * `:imu_mount_rpy` — sensor mount rotation into the vehicle frame,
      default `{0.0, 0.0, 0.0}`; applied to orientation and gyro.
    * `:imu_stale_after_ms` (200), `:minimum_imu_accuracy` (0) — age
      and calibration-status gates. A positive accuracy threshold
      requires the driver to supply a status for each consumed kind.
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

  alias Ros2Zenoh.GeometryMsgs.Msg.{
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

  alias Ros2Zenoh.NavMsgs.Msg.Odometry
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.Tf2Msgs.Msg.TFMessage
  alias RosBridge.Imu.Mount
  alias RosBridge.Publishers.Odometry.State
  alias RosBridge.{Timing, VehicleMotion}

  require Logger

  @default_topic "odom"
  @default_stale_after_ms 300
  # A longer interval means the stream was interrupted; the path across
  # the gap is unknown, so the step is dropped rather than integrated.
  @max_step_s 0.5

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

    tf_base_offset = Keyword.get(opts, :tf_ahead_of_rear_axle, base_offset)

    state = %State{
      # The TF base starts at the origin; position integrates the rear axle.
      base_offset: base_offset,
      x: -tf_base_offset,
      tf_frame_id:
        Keyword.get(opts, :tf_frame_id, Keyword.get(opts, :base_frame_id, "base_link")),
      tf_base_offset: tf_base_offset,
      imu_mount: Mount.quaternion(Keyword.get(opts, :imu_mount_rpy, {0.0, 0.0, 0.0})),
      imu_stale_after_ms: Keyword.get(opts, :imu_stale_after_ms, 200),
      minimum_imu_accuracy: Keyword.get(opts, :minimum_imu_accuracy, 0),
      topic: Keyword.get(opts, :topic, @default_topic),
      odom_frame_id: Keyword.get(opts, :odom_frame_id, "odom"),
      base_frame_id: Keyword.get(opts, :base_frame_id, "base_link"),
      stale_after_ms: Keyword.get(opts, :stale_after_ms, @default_stale_after_ms),
      pose_covariance: diagonal(Keyword.get(opts, :pose_variance, @default_pose_variance)),
      twist_covariance: diagonal(Keyword.get(opts, :twist_variance, @default_twist_variance))
    }

    open_record()
    :ok = Receiver.subscribe(self(), :ovcs, VehicleMotion.frame_name())
    driver.register_listener(self())

    Logger.info(
      "#{__MODULE__} publishing Ros2Zenoh.NavMsgs.Msg.Odometry on #{state.topic} " <>
        "and #{state.odom_frame_id} -> #{state.tf_frame_id} on tf"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:handle_frame, %Frame{name: "vehicle_motion", signals: signals}}, state) do
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

    if next_state.sequence != state.sequence and publishable?(next_state, received_at_ms) do
      publish(next_state)
      record_published(next_state, received_at_ms)
    else
      if not publishable?(next_state, received_at_ms), do: invalidate_record()
    end

    {:noreply, next_state}
  end

  # Anything else is ignored rather than fatal: a gap in odometry is
  # recoverable, a crashed publisher restarts the whole bridge subtree.
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast({:imu_sample, %Sample{} = sample}, state) do
    state = observe_imu(state, sample, System.monotonic_time(:nanosecond))
    if state.imu_reset, do: invalidate_record()
    {:noreply, state}
  end

  @doc false
  def observe_imu(state, %Sample{kind: kind} = sample, now_ns)
      when kind in [:rotation, :angular_velocity] do
    captured_at_ms =
      Integer.floor_div(sample.captured_at_ns || sample.received_at_ns || now_ns, 1_000_000)

    reference_changed =
      not is_nil(state.imu_reference) and sample.reference != state.imu_reference

    cond do
      state.imu_reset ->
        state

      reference_changed ->
        Logger.error("IMU orientation reference changed; stop navigation and restart odometry")
        %{state | imu_reset: true, last_step_yaw: nil}

      not acceptable_imu?(state, sample, captured_at_ms, now_ns / 1_000_000) ->
        state

      true ->
        state = %{state | imu_reference: sample.reference}
        apply_imu(state, sample, captured_at_ms)
    end
  end

  def observe_imu(state, _sample, _now_ns), do: state

  defp acceptable_imu?(state, sample, at_ms, now_ms) do
    accuracy = sample.accuracy || 0
    previous = if sample.kind == :rotation, do: state.yaw_at_ms, else: state.yaw_rate_at_ms

    accuracy >= state.minimum_imu_accuracy and fresh?(at_ms, now_ms, state.imu_stale_after_ms) and
      (is_nil(previous) or at_ms > previous)
  end

  defp apply_imu(state, %Sample{kind: :rotation} = sample, at_ms) do
    case Mount.orientation(sample, state.imu_mount) do
      nil ->
        state

      {x, y, z, w} ->
        yaw = yaw_from_quaternion(x, y, z, w)
        yaw_offset = state.yaw_offset || yaw
        %{state | yaw: wrap(yaw - yaw_offset), yaw_offset: yaw_offset, yaw_at_ms: at_ms}
    end
  end

  defp apply_imu(state, sample, at_ms) do
    {_x, _y, yaw_rate} = Mount.vector(sample, state.imu_mount)
    %{state | yaw_rate: yaw_rate, yaw_rate_at_ms: at_ms}
  end

  @doc """
  The state after a `vehicle_motion` sample. A retransmission (same
  sequence) cannot add distance or restore validity. A fresh sample
  integrates the arc between its heading and the previous sample's,
  unless the gap is too wide to trust or the estimate is not valid.
  """
  def observe(%State{sequence: sequence} = state, %{sequence: sequence} = sample) do
    if sample.speed_valid, do: state, else: %{state | speed_valid: false, last_step_yaw: nil}
  end

  def observe(%State{} = state, sample) do
    elapsed_s = step_seconds(state.last_fresh_at_ms, sample.at_ms)

    step_m = if integrable?(state, sample, elapsed_s), do: step_metres(state, sample, elapsed_s)

    state =
      if step_m do
        {dx, dy} = arc_step(step_m, state.last_step_yaw, state.yaw)
        %{state | x: state.x + dx, y: state.y + dy}
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
        last_fresh_at_ms: sample.at_ms,
        last_step_yaw: if(sample.speed_valid and imu_fresh?(state, sample.at_ms), do: state.yaw)
    }
  end

  # Counter difference, else speed over the interval; nil for an implausible jump.
  defp step_metres(
         %State{distance_valid: true, distance: previous_distance_m},
         %{distance_valid: true, distance: distance_m},
         _elapsed_s
       )
       when is_float(previous_distance_m) and is_float(distance_m) do
    VehicleMotion.distance_step(previous_distance_m, distance_m)
  end

  defp step_metres(state, _sample, elapsed_s), do: state.speed * elapsed_s

  defp step_seconds(nil, _now_ms), do: nil
  defp step_seconds(last_ms, now_ms), do: (now_ms - last_ms) / 1000

  defp integrable?(state, sample, elapsed_s) do
    state.speed_valid and sample.speed_valid and not is_nil(state.last_step_yaw) and
      imu_fresh?(state, sample.at_ms) and not is_nil(elapsed_s) and elapsed_s > 0 and
      elapsed_s <= min(@max_step_s, state.imu_stale_after_ms / 1000)
  end

  @doc false
  def publishable?(%State{} = state, now_ms) do
    state.speed_valid and imu_fresh?(state, now_ms) and
      fresh?(state.last_fresh_at_ms, now_ms, state.stale_after_ms)
  end

  defp imu_fresh?(state, now_ms) do
    not state.imu_reset and not is_nil(state.yaw) and
      fresh?(state.yaw_at_ms, now_ms, state.imu_stale_after_ms) and
      fresh?(state.yaw_rate_at_ms, now_ms, state.imu_stale_after_ms)
  end

  defp fresh?(nil, _now_ms, _timeout_ms), do: false
  defp fresh?(at_ms, now_ms, timeout_ms), do: now_ms >= at_ms and now_ms - at_ms <= timeout_ms

  @doc false
  def arc_step(distance, previous_yaw, yaw) do
    half_turn = wrap(yaw - previous_yaw) / 2
    chord_factor = if abs(half_turn) < 1.0e-9, do: 1.0, else: :math.sin(half_turn) / half_turn
    heading = previous_yaw + half_turn
    {distance * chord_factor * :math.cos(heading), distance * chord_factor * :math.sin(heading)}
  end

  defp wrap(angle), do: :math.atan2(:math.sin(angle), :math.cos(angle))

  @doc """
  Whether `odom → base_link` went out within the publisher's
  `:stale_after_ms` of `now_ms` (monotonic milliseconds). True where no
  odometry publisher runs, so a vehicle without one publishes its range
  readings as they come. Pass `false` as the second argument to require
  a running publisher, as the autonomous velocity consumer does.
  """
  def publishing?(now_ms \\ now_ms(), without_publisher \\ true) do
    case :ets.lookup(__MODULE__, :published) do
      [{:published, at_ms, stale_after_ms}] -> now_ms - at_ms <= stale_after_ms
      [] -> false
    end
  rescue
    # No table: no odometry publisher.
    ArgumentError -> without_publisher
  end

  defp invalidate_record do
    :ets.delete(__MODULE__, :published)
  rescue
    ArgumentError -> false
  end

  @doc false
  def open_record, do: :ets.new(__MODULE__, [:named_table, read_concurrency: true])

  @doc false
  def record_published(state, at_ms) do
    imu_remaining_ms =
      min(state.yaw_at_ms, state.yaw_rate_at_ms) + state.imu_stale_after_ms - at_ms

    timeout_ms = min(state.stale_after_ms, imu_remaining_ms)
    :ets.insert(__MODULE__, {:published, at_ms, timeout_ms})
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

  @doc false
  def messages(%State{} = state) do
    stamp = Timing.stamp_from_monotonic(round(state.last_fresh_at_ms * 1_000_000))
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

    tf_offset = state.tf_base_offset || state.base_offset
    tf_x = state.x + tf_offset * :math.cos(state.yaw)
    tf_y = state.y + tf_offset * :math.sin(state.yaw)

    transform = %TransformStamped{
      header: %Header{stamp: stamp, frame_id: state.odom_frame_id},
      child_frame_id: state.tf_frame_id || state.base_frame_id,
      transform: %Transform{
        translation: %Vector3{x: tf_x, y: tf_y, z: 0.0},
        rotation: orientation
      }
    }

    {odometry, transform}
  end

  defp publish(state) do
    {odometry, transform} = messages(state)
    Ros2Zenoh.Client.publish(state.topic, Odometry, odometry)
    Ros2Zenoh.Client.publish("tf", TFMessage, %TFMessage{transforms: [transform]})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
