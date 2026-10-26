defmodule RosBridge.Publishers.PathPrediction do
  @moduledoc """
  Where the vehicle is heading, from the VMS's `vehicle_motion` frame
  (`0x60B`) and the gear on `gear_status` (`0x600`), in `base_link`:

    * `vehicle/predicted_path` (`nav_msgs/Path`) — the arc `base_link`
      follows over the next `:length_m` at the commanded steering
      angle, ahead in drive and behind in reverse, or along the
      direction of travel while moving;
    * `vehicle/predicted_pose` (`geometry_msgs/PoseStamped`) — where
      `base_link` will be in `:horizon_s` at the current speed, published
      only while moving.

  A bicycle model about the rear axle: curvature `tan(δ) / wheelbase`,
  `base_link` `:base_ahead_of_rear_axle` along the heading from it. The
  steering angle is the commanded one; the servo reports none.

  ## Options

    * `:wheelbase` (required) — metres between the axles.
    * `:base_ahead_of_rear_axle` (default 0.0), as for
      `RosBridge.Publishers.Odometry`.
    * `:base_frame_id` (`"base_link"`), `:path_topic`, `:pose_topic`.
    * `:length_m` (default 2.5), `:horizon_s` (default 1.0),
      `:step_m` (default 0.05).
    * `:interval_ms` (default 50) — the shortest time between two
      publications; the frame arrives faster than anyone reads a path.
  """
  use GenServer
  require Logger

  alias Cantastic.{Frame, Receiver, Signal}
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, PoseStamped, Quaternion}
  alias Ros2.NavMsgs.Msg.Path
  alias Ros2.StdMsgs.Msg.Header
  alias RosBridge.{Timing, VehicleMotion}

  @moving_speed_m_s 0.05

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    state = %{
      wheelbase: Keyword.fetch!(opts, :wheelbase) * 1.0,
      base_offset: Keyword.get(opts, :base_ahead_of_rear_axle, 0.0) * 1.0,
      base_frame_id: Keyword.get(opts, :base_frame_id, "base_link"),
      path_topic: Keyword.get(opts, :path_topic, "vehicle/predicted_path"),
      pose_topic: Keyword.get(opts, :pose_topic, "vehicle/predicted_pose"),
      length_m: Keyword.get(opts, :length_m, 2.5),
      horizon_s: Keyword.get(opts, :horizon_s, 1.0),
      step_m: Keyword.get(opts, :step_m, 0.05),
      interval_ms: Keyword.get(opts, :interval_ms, 50),
      gear: nil,
      published_at_ms: nil
    }

    :ok = Receiver.subscribe(self(), :ovcs, VehicleMotion.frame_name())
    :ok = Receiver.subscribe(self(), :ovcs, "gear_status")
    Logger.info("#{__MODULE__} publishing #{state.path_topic} and #{state.pose_topic}")
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:handle_frame, %Frame{name: "gear_status", signals: signals}}, state) do
    %{"selected_gear" => %Signal{value: gear}} = signals
    {:noreply, %{state | gear: gear}}
  end

  def handle_info({:handle_frame, %Frame{name: "vehicle_motion", signals: signals}}, state) do
    %{
      "speed" => %Signal{value: speed},
      "steering_angle" => %Signal{value: steering_angle},
      "speed_valid" => %Signal{value: speed_valid}
    } = signals

    now_ms = System.monotonic_time(:millisecond)

    if speed_valid == true and due?(state, now_ms) do
      publish(state, Decimal.to_float(speed), Decimal.to_float(steering_angle))
      {:noreply, %{state | published_at_ms: now_ms}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp due?(%{published_at_ms: nil}, _now_ms), do: true
  defp due?(state, now_ms), do: now_ms - state.published_at_ms >= state.interval_ms

  defp publish(state, speed, steering_angle) do
    header = %Header{
      stamp: Timing.stamp_from_system_time(System.system_time(:nanosecond)),
      frame_id: state.base_frame_id
    }

    curvature = curvature(steering_angle, state.wheelbase)
    length_m = direction(speed, state.gear) * state.length_m

    poses =
      arc(curvature, length_m, state.step_m, state.base_offset)
      |> Enum.map(&%PoseStamped{header: header, pose: &1})

    RosBridge.ZenohClient.publish(state.path_topic, Path, %Path{header: header, poses: poses})

    if abs(speed) >= @moving_speed_m_s do
      pose = pose_at(curvature, speed * state.horizon_s, state.base_offset)

      RosBridge.ZenohClient.publish(state.pose_topic, PoseStamped, %PoseStamped{
        header: header,
        pose: pose
      })
    end
  end

  @doc "The curvature, 1/m, positive left, of a bicycle steered `steering_angle` radians. Pure."
  def curvature(steering_angle, wheelbase), do: :math.tan(steering_angle) / wheelbase

  @doc """
  +1 ahead, -1 behind: the direction of travel while moving, else the
  gear's. Pure.
  """
  def direction(speed, _gear) when speed >= @moving_speed_m_s, do: 1
  def direction(speed, _gear) when speed <= -@moving_speed_m_s, do: -1
  def direction(_speed, gear) when gear in [:reverse, "reverse"], do: -1
  def direction(_speed, _gear), do: 1

  @doc """
  `base_link`'s poses along `length_m` (negative behind) of an arc of
  `curvature`, every `step_m`, in its own starting frame. Pure.
  """
  def arc(curvature, length_m, step_m, base_offset) do
    steps = max(round(abs(length_m) / step_m), 1)
    for index <- 0..steps, do: pose_at(curvature, length_m * index / steps, base_offset)
  end

  @doc """
  `base_link`'s pose after its rear axle rolls `distance_m` (negative
  behind) along an arc of `curvature`, in `base_link`'s starting frame.
  Pure.
  """
  def pose_at(curvature, distance_m, base_offset) do
    heading = curvature * distance_m

    {rear_x, rear_y} =
      if abs(curvature) < 1.0e-6,
        do: {distance_m, 0.0},
        else: {:math.sin(heading) / curvature, (1.0 - :math.cos(heading)) / curvature}

    %Pose{
      position: %Point{
        x: rear_x - base_offset + base_offset * :math.cos(heading),
        y: rear_y + base_offset * :math.sin(heading),
        z: 0.0
      },
      orientation: %Quaternion{
        x: 0.0,
        y: 0.0,
        z: :math.sin(heading / 2),
        w: :math.cos(heading / 2)
      }
    }
  end
end
