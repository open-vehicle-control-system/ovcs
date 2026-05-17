defmodule RosBridge.ImuPublisher.State do
  @moduledoc false
  defstruct [
    :imu_source,
    :topic,
    :frame_id,
    :publish_interval_ms,
    latest_orientation: nil,
    latest_angular_velocity: nil,
    latest_linear_acceleration: nil
  ]
end

defmodule RosBridge.ImuPublisher do
  @moduledoc """
  Coalesces `RosBridge.ImuSource.Reading`s into `sensor_msgs/Imu`
  samples and publishes them via `RosBridge.ZenohClient.publish/4`.

  Knows nothing about the underlying sensor — any module implementing
  the `RosBridge.ImuSource` behaviour plugs in via the `:imu_source`
  option.

  Readings arrive independently per kind; we keep the freshest of
  each and publish a single coalesced `Imu` at 50 Hz. The tick is a
  no-op until all three kinds have been seen at least once (avoids
  emitting half-filled messages).

  TODO: characterize the source's noise floor and populate
  `*_covariance` arrays with measured values instead of the zero
  sentinel ("covariance unknown" per the ROS message definition).
  """
  use GenServer

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.SensorMsgs.Msg.Imu
  alias Ros2.StdMsgs.Msg.Header
  alias RosBridge.ImuPublisher.State
  alias RosBridge.ImuSource.Reading

  require Logger

  @default_topic "imu"
  @default_frame_id "imu_link"
  # 50 Hz — fast enough for Foxglove's IMU visualizer to feel live,
  # slow enough not to drown a downstream consumer in samples.
  @default_publish_interval_ms 20

  # Nine-element zero list, the ROS sentinel for "covariance unknown"
  # (per the comment in the upstream sensor_msgs/Imu.msg IDL).
  @unknown_covariance List.duplicate(0.0, 9)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    imu_source = Keyword.fetch!(opts, :imu_source)

    state = %State{
      imu_source: imu_source,
      topic: Keyword.get(opts, :topic, @default_topic),
      frame_id: Keyword.get(opts, :frame_id, @default_frame_id),
      publish_interval_ms:
        Keyword.get(opts, :publish_interval_ms, @default_publish_interval_ms)
    }

    imu_source.register_listener(self())
    imu_source.enable()
    Process.send_after(self(), :tick, state.publish_interval_ms)

    Logger.info(
      "#{__MODULE__} publishing Ros2.SensorMsgs.Msg.Imu on " <>
        "#{state.topic} every #{state.publish_interval_ms}ms " <>
        "(frame #{state.frame_id}, source #{inspect(imu_source)})"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:imu_reading, %Reading{kind: :linear_acceleration, value: value}}, state) do
    {:noreply, %{state | latest_linear_acceleration: value}}
  end

  def handle_cast({:imu_reading, %Reading{kind: :angular_velocity, value: value}}, state) do
    {:noreply, %{state | latest_angular_velocity: value}}
  end

  def handle_cast({:imu_reading, %Reading{kind: :orientation, value: value}}, state) do
    {:noreply, %{state | latest_orientation: value}}
  end

  @impl true
  def handle_info(:tick, %State{} = state) do
    if ready_to_publish?(state) do
      publish_imu(state)
    end

    Process.send_after(self(), :tick, state.publish_interval_ms)
    {:noreply, state}
  end

  defp ready_to_publish?(%State{
         latest_orientation: orientation,
         latest_angular_velocity: angular_velocity,
         latest_linear_acceleration: linear_acceleration
       }) do
    not is_nil(orientation) and not is_nil(angular_velocity) and not is_nil(linear_acceleration)
  end

  defp publish_imu(%State{} = state) do
    now_ns = System.system_time(:nanosecond)

    message = %Imu{
      header: %Header{
        stamp: %Time{
          sec: div(now_ns, 1_000_000_000),
          nanosec: rem(now_ns, 1_000_000_000)
        },
        frame_id: state.frame_id
      },
      orientation: state.latest_orientation,
      orientation_covariance: @unknown_covariance,
      angular_velocity: state.latest_angular_velocity,
      angular_velocity_covariance: @unknown_covariance,
      linear_acceleration: state.latest_linear_acceleration,
      linear_acceleration_covariance: @unknown_covariance
    }

    RosBridge.ZenohClient.publish(state.topic, Imu, message)
  end
end
