defmodule RosBridge.Publishers.Imu.State do
  @moduledoc false
  defstruct [
    :driver,
    :topic,
    :frame_id,
    :publish_interval_ms,
    stale_after_ms: 200,
    max_sample_skew_ms: 50,
    samples: %{},
    published_at_ns: %{}
  ]
end

defmodule RosBridge.Publishers.Imu do
  @moduledoc """
  Coalesces independent driver samples into `sensor_msgs/Imu` messages.
  Every kind must be fresh and newer than its last publication. The
  orientation's capture time stamps the message; gyro and acceleration
  must be within `:max_sample_skew_ms` (default 50) of it. No cached
  sample is restamped as a new measurement.

  Options: `:driver` (required), `:topic` ("imu"), `:frame_id`
  ("imu_link"), `:publish_interval_ms` (20), `:stale_after_ms` (200),
  and `:max_sample_skew_ms` (50). Drivers without timestamps are
  stamped on receipt. Covariances remain unknown until measured.
  """
  use GenServer

  alias OvcsDrivers.Imu.Sample
  alias Ros2Zenoh.GeometryMsgs.Msg.{Quaternion, Vector3}
  alias Ros2Zenoh.SensorMsgs.Msg.Imu
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias RosBridge.Imu.Mount
  alias RosBridge.Publishers.Imu.State
  alias RosBridge.Timing

  @kinds [:rotation, :angular_velocity, :acceleration]
  @unknown_covariance List.duplicate(0.0, 9)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)

    state = %State{
      driver: driver,
      topic: Keyword.get(opts, :topic, "imu"),
      frame_id: Keyword.get(opts, :frame_id, "imu_link"),
      publish_interval_ms: Keyword.get(opts, :publish_interval_ms, 20),
      stale_after_ms: Keyword.get(opts, :stale_after_ms, 200),
      max_sample_skew_ms: Keyword.get(opts, :max_sample_skew_ms, 50)
    }

    driver.register_listener(self())
    driver.enable()
    Process.send_after(self(), :tick, state.publish_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:imu_sample, %Sample{} = sample}, state) do
    {:noreply, observe(state, sample, System.monotonic_time(:nanosecond))}
  end

  @doc false
  def observe(state, %Sample{kind: kind} = sample, now_ns) when kind in @kinds do
    captured_at_ns = sample.captured_at_ns || sample.received_at_ns || now_ns
    previous = state.samples[kind]

    if is_nil(previous) or captured_at_ns > previous.captured_at_ns do
      %{state | samples: Map.put(state.samples, kind, %{sample | captured_at_ns: captured_at_ns})}
    else
      state
    end
  end

  def observe(state, _sample, _now_ns), do: state

  @impl GenServer
  def handle_info(:tick, state) do
    state =
      if ready_to_publish?(state, System.monotonic_time(:nanosecond)) do
        Ros2Zenoh.Client.publish(state.topic, Imu, message(state))

        %{
          state
          | published_at_ns:
              Map.new(state.samples, fn {kind, sample} -> {kind, sample.captured_at_ns} end)
        }
      else
        state
      end

    Process.send_after(self(), :tick, state.publish_interval_ms)
    {:noreply, state}
  end

  @doc false
  def ready_to_publish?(state, now_ns) do
    Enum.all?(@kinds, &fresh_sample?(state, &1, now_ns)) and coherent?(state)
  end

  defp fresh_sample?(state, kind, now_ns) do
    case state.samples[kind] do
      nil ->
        false

      sample ->
        age_ns = now_ns - sample.captured_at_ns
        published_at_ns = state.published_at_ns[kind]

        age_ns >= 0 and age_ns <= state.stale_after_ms * 1_000_000 and
          (is_nil(published_at_ns) or sample.captured_at_ns > published_at_ns)
    end
  end

  defp coherent?(state) do
    samples = Map.values(state.samples)
    times = Enum.map(samples, & &1.captured_at_ns)

    Enum.max(times) - Enum.min(times) <= state.max_sample_skew_ms * 1_000_000 and
      length(Enum.uniq_by(samples, & &1.reference)) == 1 and
      not is_nil(Mount.orientation(state.samples.rotation, {0.0, 0.0, 0.0, 1.0}))
  end

  @doc false
  def message(state) do
    rotation = state.samples.rotation
    {x, y, z, w} = Mount.orientation(rotation, {0.0, 0.0, 0.0, 1.0})

    %Imu{
      header: %Header{
        stamp: Timing.stamp_from_monotonic(rotation.captured_at_ns),
        frame_id: state.frame_id
      },
      orientation: %Quaternion{x: x, y: y, z: z, w: w},
      orientation_covariance: @unknown_covariance,
      angular_velocity: vector(state.samples.angular_velocity),
      angular_velocity_covariance: @unknown_covariance,
      linear_acceleration: vector(state.samples.acceleration),
      linear_acceleration_covariance: @unknown_covariance
    }
  end

  defp vector(sample), do: %Vector3{x: sample.x, y: sample.y, z: sample.z}
end
