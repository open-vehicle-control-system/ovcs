defmodule RosBridge.Perception.Proximity do
  @moduledoc """
  How close the lidar's surroundings are, from a `sensor_msgs/LaserScan`
  topic, in the scan's frame:

    * `proximity/nearest` (`sensor_msgs/Range`) — the nearest return,
      `+∞` when there is none within `:within_m`;
    * `proximity/labels` (`visualization_msgs/MarkerArray`) — per
      sector of `:sector_deg`, the nearest return within `:within_m`,
      a dot and its distance in metres: red within `:danger_m`, amber
      within `:caution_m`, white beyond. Every array starts by deleting
      the last one, so a sector that empties drops its label.

  ## Options

    * `:scan_topic` (`"scan"`), `:nearest_topic`, `:labels_topic`.
    * `:within_m` (default 3.0), `:sector_deg` (default 30),
      `:danger_m` (default 0.5), `:caution_m` (default 1.0).
  """
  use GenServer
  require Logger

  alias Ros2.GeometryMsgs.Msg.{Point, Pose, Vector3}
  alias Ros2.SensorMsgs.Msg.{LaserScan, Range}
  alias Ros2.StdMsgs.Msg.ColorRGBA
  alias Ros2.VisualizationMsgs.Msg.{Marker, MarkerArray}

  @namespace "proximity"
  @danger %ColorRGBA{r: 1.0, g: 0.3, b: 0.27, a: 1.0}
  @caution %ColorRGBA{r: 1.0, g: 0.72, b: 0.25, a: 1.0}
  @clear %ColorRGBA{r: 0.94, g: 0.96, b: 0.98, a: 1.0}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    state = %{
      nearest_topic: Keyword.get(opts, :nearest_topic, "proximity/nearest"),
      labels_topic: Keyword.get(opts, :labels_topic, "proximity/labels"),
      within_m: Keyword.get(opts, :within_m, 3.0),
      sector_rad: Keyword.get(opts, :sector_deg, 30) * :math.pi() / 180,
      danger_m: Keyword.get(opts, :danger_m, 0.5),
      caution_m: Keyword.get(opts, :caution_m, 1.0)
    }

    scan_topic = Keyword.get(opts, :scan_topic, "scan")
    :ok = RosBridge.ZenohClient.subscribe(scan_topic, LaserScan)
    Logger.info("#{__MODULE__} on #{scan_topic}: #{state.nearest_topic}, #{state.labels_topic}")
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:ros_message, {_key_expr, %LaserScan{} = scan}}, state) do
    returns = returns_within(scan, state.within_m)
    RosBridge.ZenohClient.publish(state.nearest_topic, Range, nearest(scan, returns))
    RosBridge.ZenohClient.publish(state.labels_topic, MarkerArray, labels(scan, returns, state))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "The scan's returns within `within_m`, as `{angle, range}`. Pure."
  def returns_within(%LaserScan{} = scan, within_m) do
    scan.ranges
    |> Enum.with_index()
    |> Enum.filter(fn {range, _index} ->
      is_float(range) and range >= scan.range_min and range <= min(scan.range_max, within_m)
    end)
    |> Enum.map(fn {range, index} -> {scan.angle_min + index * scan.angle_increment, range} end)
  end

  @doc "The nearest of `returns` as a `Range`. Pure."
  def nearest(%LaserScan{} = scan, returns) do
    %Range{
      header: scan.header,
      radiation_type: :infrared,
      field_of_view: scan.angle_max - scan.angle_min,
      min_range: scan.range_min,
      max_range: scan.range_max,
      range:
        case returns do
          [] -> :infinity
          _ -> returns |> Enum.map(&elem(&1, 1)) |> Enum.min()
        end
    }
  end

  @doc "The nearest return of each sector, labelled. Pure."
  def labels(%LaserScan{} = scan, returns, state) do
    labelled =
      returns
      |> Enum.group_by(fn {angle, _range} -> floor(angle / state.sector_rad) end)
      |> Enum.map(fn {_sector, in_sector} -> Enum.min_by(in_sector, &elem(&1, 1)) end)
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.flat_map(fn {{angle, range}, index} ->
        label_markers(scan, angle, range, index, state)
      end)

    clear = %Marker{header: scan.header, ns: @namespace, action: Marker.delete_all()}
    %MarkerArray{markers: [clear | labelled]}
  end

  defp label_markers(scan, angle, range, index, state) do
    at = %Point{x: range * :math.cos(angle), y: range * :math.sin(angle), z: 0.0}
    colour = colour(range, state)

    [
      %Marker{
        header: scan.header,
        ns: @namespace,
        id: 2 * index,
        type: Marker.sphere(),
        pose: %Pose{position: at},
        scale: %Vector3{x: 0.03, y: 0.03, z: 0.03},
        color: colour
      },
      %Marker{
        header: scan.header,
        ns: @namespace,
        id: 2 * index + 1,
        type: Marker.text_view_facing(),
        pose: %Pose{position: %{at | z: 0.06}},
        # Only scale.z, the text height in metres, is read for text.
        scale: %Vector3{x: 0.0, y: 0.0, z: 0.05},
        color: colour,
        text: :erlang.float_to_binary(range, decimals: 2)
      }
    ]
  end

  defp colour(range, state) do
    cond do
      range < state.danger_m -> @danger
      range < state.caution_m -> @caution
      true -> @clear
    end
  end
end
