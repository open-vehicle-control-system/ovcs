defmodule RosBridge.Publishers.LaserScan do
  @moduledoc """
  Publishes each revolution from an `OvcsDrivers.Lidar` driver as a
  `sensor_msgs/LaserScan`.

  `LaserScan` wants ranges at evenly spaced angles, and a spinning
  sensor's measurements are not, so each revolution is binned into
  `:bins` slots over `[-π, π)`, each keeping its nearest return (an
  obstacle is never hidden by a farther point in the same slot) and
  0.0 when it has none. `time_increment` is 0: the bins are not in
  measurement order.

  ## Options

    * `:driver` (required) — the `OvcsDrivers.Lidar` module
    * `:topic` (`"scan"`), `:frame_id` (`"laser"`)
    * `:bins` (720, half a degree)
  """
  use GenServer
  require Logger

  alias OvcsDrivers.Lidar.Scan
  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.SensorMsgs.Msg.LaserScan
  alias Ros2.StdMsgs.Msg.Header

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)

    state = %{
      topic: Keyword.get(opts, :topic, "scan"),
      frame_id: Keyword.get(opts, :frame_id, "laser"),
      bins: Keyword.get(opts, :bins, 720)
    }

    driver.register_listener(self())
    driver.enable()

    Logger.info(
      "#{__MODULE__} publishing #{state.topic} (frame #{state.frame_id}, driver #{inspect(driver)})"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:lidar_scan, %Scan{} = scan}, state) do
    RosBridge.ZenohClient.publish(
      state.topic,
      LaserScan,
      laser_scan(scan, state.bins, state.frame_id)
    )

    {:noreply, state}
  end

  @doc "The `LaserScan` for `scan` binned into `bins` slots. Pure."
  def laser_scan(%Scan{range: {range_min, range_max}} = scan, bins, frame_id) do
    increment = 2 * :math.pi() / bins

    slots =
      Enum.reduce(scan.points, %{}, fn
        {_angle, distance, _quality}, slots when distance < range_min or distance > range_max ->
          slots

        {angle, distance, quality}, slots ->
          slot = slot(angle, increment, bins)

          Map.update(slots, slot, {distance, quality}, fn {kept, _} = existing ->
            if distance < kept, do: {distance, quality}, else: existing
          end)
      end)

    {ranges, intensities} =
      Enum.map(0..(bins - 1), &Map.get(slots, &1, {0.0, 0})) |> Enum.unzip()

    %LaserScan{
      header: %Header{stamp: time(scan.started_at), frame_id: frame_id},
      angle_min: -:math.pi(),
      angle_max: :math.pi() - increment,
      angle_increment: increment,
      time_increment: 0.0,
      scan_time: scan.duration_ns / 1.0e9,
      range_min: range_min,
      range_max: range_max,
      ranges: ranges,
      intensities: Enum.map(intensities, &(&1 * 1.0))
    }
  end

  # Angles arrive in [0, 2π); slot 0 starts at -π.
  defp slot(angle, increment, bins) do
    wrapped = if angle >= :math.pi(), do: angle - 2 * :math.pi(), else: angle
    min(trunc((wrapped + :math.pi()) / increment), bins - 1)
  end

  defp time(system_ns),
    do: %Time{sec: div(system_ns, 1_000_000_000), nanosec: rem(system_ns, 1_000_000_000)}
end
