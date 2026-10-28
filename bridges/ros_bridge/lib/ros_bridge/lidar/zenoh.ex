defmodule RosBridge.Lidar.Zenoh do
  @moduledoc """
  A lidar that is somewhere else: subscribes to a ROS
  `sensor_msgs/LaserScan` topic and hands each scan on as the
  `%OvcsDrivers.Lidar.Scan{}` a `RPLidar.UART` produces, so
  `Publishers.LaserScan` republishes it on `/scan` as on the vehicle.
  The `RosBridge.Imu.Zenoh` pattern, for Gazebo's lidar.

  Finite ranges pass through as the RPLIDAR's do, for
  `Publishers.LaserScan` to classify; an infinity or NaN becomes the
  `0.0` of no return. `:started_at` is the time of receipt.

  ## Options

    * `:topic` (`"scan_raw"`) — the ROS topic to consume.
  """
  @behaviour OvcsDrivers.Lidar

  use GenServer

  require Logger

  alias OvcsDrivers.Lidar.Scan
  alias Ros2Zenoh.SensorMsgs.Msg.LaserScan

  @default_topic "scan_raw"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl OvcsDrivers.Lidar
  def register_listener(listener), do: GenServer.cast(__MODULE__, {:register_listener, listener})

  @doc "No-op: scans flow when the simulator publishes."
  @impl OvcsDrivers.Lidar
  def enable, do: :ok

  @impl GenServer
  def init(opts) do
    topic = Keyword.get(opts, :topic, @default_topic)
    :ok = RosBridge.ZenohClient.subscribe(topic, LaserScan)
    Logger.info("#{__MODULE__} consuming #{topic}")
    {:ok, %{listeners: []}}
  end

  @impl GenServer
  def handle_cast({:register_listener, listener}, state),
    do: {:noreply, %{state | listeners: state.listeners ++ [listener]}}

  @impl GenServer
  def handle_info({:ros_message, {_key_expr, %LaserScan{} = laser_scan}}, state) do
    scan = scan(laser_scan, System.system_time(:nanosecond))
    Enum.each(state.listeners, &GenServer.cast(&1, {:lidar_scan, scan}))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "The `Scan` for `laser_scan`, received at `received_at` (system ns). Pure."
  def scan(%LaserScan{range_min: range_min, range_max: range_max} = laser_scan, received_at) do
    points =
      laser_scan.ranges
      |> Enum.with_index()
      |> Enum.map(fn {range, index} ->
        angle = laser_scan.angle_min + index * laser_scan.angle_increment

        if is_float(range), do: {wrap(angle), range, 1}, else: {wrap(angle), 0.0, 0}
      end)

    %Scan{
      points: points,
      started_at: received_at,
      duration_ns:
        if(is_float(laser_scan.scan_time), do: round(laser_scan.scan_time * 1.0e9), else: 0),
      range: {range_min, range_max}
    }
  end

  # Into the `[0, 2π)` of `Scan`.
  defp wrap(angle) do
    full_turn = 2 * :math.pi()
    wrapped = angle - full_turn * Float.floor(angle / full_turn)
    if wrapped >= full_turn, do: 0.0, else: wrapped
  end
end
