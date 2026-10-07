defmodule RosBridge.Publishers.Range do
  @moduledoc """
  Publishes each measurement from an `OvcsDrivers.Rangefinder` driver
  instance as a `sensor_msgs/Range`, with REP 117's infinities for a
  reading outside the sensor's range. One per sensor.

  ## Options

    * `:driver` (required) — the `OvcsDrivers.Rangefinder` module
    * `:name` (required) — the driver instance's name
    * `:topic`, `:frame_id` (required)
    * `:radiation_type` — `:ultrasound` (default) or `:infrared`
    * `:marker_topic` — also publish each measurement as a
      `visualization_msgs/MarkerArray` for 3D viewers, which do not
      draw `Range`: the outline of a fan the width of the beam, cut at
      the distance, red near and green far, grey out to the maximum
      range when nothing is in range. An outline, because the filled
      fans of sensors mounted side by side are coplanar where they
      overlap, and a viewer flickers between them
  """
  use GenServer
  require Logger

  alias OvcsDrivers.Rangefinder.Sample
  alias Ros2.BuiltinInterfaces.Msg.{Duration, Time}
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, Quaternion, Vector3}
  alias Ros2.StdMsgs.Msg.ColorRGBA
  alias Ros2.VisualizationMsgs.Msg.{Marker, MarkerArray}
  alias Ros2.SensorMsgs.Msg.Range
  alias Ros2.StdMsgs.Msg.Header

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)

    state = %{
      topic: Keyword.fetch!(opts, :topic),
      frame_id: Keyword.fetch!(opts, :frame_id),
      radiation_type: Keyword.get(opts, :radiation_type, :ultrasound),
      marker_topic: Keyword.get(opts, :marker_topic)
    }

    driver.register_listener(Keyword.fetch!(opts, :name), self())
    Logger.info("#{__MODULE__} publishing #{state.topic} (frame #{state.frame_id})")
    {:ok, state}
  end

  @impl true
  def handle_cast({:range_sample, %Sample{} = sample}, state) do
    RosBridge.ZenohClient.publish(state.topic, Range, range(sample, state))

    if state.marker_topic,
      do:
        RosBridge.ZenohClient.publish(state.marker_topic, MarkerArray, %MarkerArray{
          markers: [marker(sample, state)]
        })

    {:noreply, state}
  end

  @doc "The `Range` for `sample`. Pure."
  def range(%Sample{range: {min, max}} = sample, state) do
    %Range{
      header: %Header{stamp: time(sample.measured_at), frame_id: state.frame_id},
      radiation_type: state.radiation_type,
      field_of_view: sample.field_of_view,
      min_range: min,
      max_range: max,
      range:
        case sample.distance do
          :below_range -> :neg_infinity
          :beyond_range -> :infinity
          metres -> metres
        end
    }
  end

  # Segments of the fan's arc.
  @fan_segments 12
  # A sensor reports ten times a second; a marker outlives two misses.
  @marker_lifetime %Duration{sec: 0, nanosec: 300_000_000}

  @doc "The fan outline for `sample`, in the sensor's frame (x along the beam). Pure."
  def marker(%Sample{range: {min, max}} = sample, state) do
    {length, colour} =
      case sample.distance do
        :beyond_range -> {max, %ColorRGBA{r: 0.6, g: 0.6, b: 0.6, a: 0.3}}
        :below_range -> {min, %ColorRGBA{r: 1.0, g: 0.0, b: 0.0, a: 1.0}}
        metres -> {metres, near_far(metres, max)}
      end

    half = sample.field_of_view / 2

    arc =
      for i <- 0..@fan_segments do
        angle = -half + i * sample.field_of_view / @fan_segments
        %Point{x: length * :math.cos(angle), y: length * :math.sin(angle), z: 0.0}
      end

    apex = %Point{}

    %Marker{
      header: %Header{stamp: time(sample.measured_at), frame_id: state.frame_id},
      ns: state.frame_id,
      id: 0,
      type: Marker.line_strip(),
      action: Marker.add(),
      pose: %Pose{position: %Point{}, orientation: %Quaternion{x: 0.0, y: 0.0, z: 0.0, w: 1.0}},
      # A line strip's width, in metres.
      scale: %Vector3{x: 0.008, y: 0.0, z: 0.0},
      color: colour,
      lifetime: @marker_lifetime,
      points: [apex | arc] ++ [apex]
    }
  end

  # Red at 0 m to green at the maximum range.
  defp near_far(metres, max) do
    t = min(metres / max, 1.0)
    %ColorRGBA{r: 1.0 - t, g: t, b: 0.0, a: 1.0}
  end

  defp time(system_ns),
    do: %Time{sec: div(system_ns, 1_000_000_000), nanosec: rem(system_ns, 1_000_000_000)}
end
