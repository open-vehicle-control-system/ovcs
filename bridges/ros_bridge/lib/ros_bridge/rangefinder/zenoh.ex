defmodule RosBridge.Rangefinder.Zenoh do
  @moduledoc """
  A rangefinder that is somewhere else: subscribes to a ROS
  `sensor_msgs/LaserScan` topic, a simulator's narrow fan standing in
  for one beam, and hands its nearest return on as the
  `%OvcsDrivers.Rangefinder.Sample{}` an `A02YYUW.UART` produces, so
  `Publishers.Range` republishes it as on the vehicle. The
  `RosBridge.Imu.Zenoh` pattern, for Gazebo's ultrasonics.

  The fan's span is the sample's field of view; `:measured_at` is the
  time of receipt.

  ## Options

    * `:name` (required) — the instance's name, unique per sensor
    * `:topic` (required) — the ROS topic to consume
  """
  @behaviour OvcsDrivers.Rangefinder

  use GenServer

  require Logger

  alias OvcsDrivers.Rangefinder.Sample
  alias Ros2.SensorMsgs.Msg.LaserScan

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def child_spec(opts),
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}

  @impl OvcsDrivers.Rangefinder
  def register_listener(server, listener),
    do: GenServer.cast(server, {:register_listener, listener})

  @impl GenServer
  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    :ok = RosBridge.ZenohClient.subscribe(topic, LaserScan)
    Logger.info("#{__MODULE__} #{Keyword.fetch!(opts, :name)} consuming #{topic}")
    {:ok, %{listeners: []}}
  end

  @impl GenServer
  def handle_cast({:register_listener, listener}, state),
    do: {:noreply, %{state | listeners: state.listeners ++ [listener]}}

  @impl GenServer
  def handle_info({:ros_message, {_key_expr, %LaserScan{} = laser_scan}}, state) do
    sample = sample(laser_scan, System.system_time(:nanosecond))
    Enum.each(state.listeners, &GenServer.cast(&1, {:range_sample, sample}))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "The `Sample` for `laser_scan`, received at `received_at` (system ns). Pure."
  def sample(%LaserScan{range_min: range_min, range_max: range_max} = laser_scan, received_at) do
    %Sample{
      distance: distance(laser_scan.ranges, range_min, range_max),
      range: {range_min, range_max},
      field_of_view: laser_scan.angle_max - laser_scan.angle_min,
      measured_at: received_at
    }
  end

  # Gazebo reports a ray with no return as +∞ and one below range_min as -∞.
  defp distance(ranges, range_min, range_max) do
    nearest =
      ranges
      |> Enum.map(&if(&1 == :neg_infinity, do: 0.0, else: &1))
      |> Enum.min(fn -> :infinity end)

    cond do
      not is_float(nearest) or nearest > range_max -> :beyond_range
      nearest < range_min -> :below_range
      true -> nearest
    end
  end
end
