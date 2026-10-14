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
    * `:beyond_range` — what a reading beyond the sensor's range
      publishes: `:infinity` (default, REP 117) or `:max_range`, for
      Nav2's `RangeSensorLayer`, which drops infinities and clears only
      on a reading of exactly `max_range`
  """
  use GenServer
  require Logger

  alias OvcsDrivers.Rangefinder.Sample
  alias Ros2.SensorMsgs.Msg.Range
  alias Ros2.StdMsgs.Msg.Header
  alias RosBridge.Timing

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}

  @impl GenServer
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)

    state = %{
      topic: Keyword.fetch!(opts, :topic),
      frame_id: Keyword.fetch!(opts, :frame_id),
      radiation_type: Keyword.get(opts, :radiation_type, :ultrasound),
      beyond_range: Keyword.get(opts, :beyond_range, :infinity)
    }

    driver.register_listener(Keyword.fetch!(opts, :name), self())
    Logger.info("#{__MODULE__} publishing #{state.topic} (frame #{state.frame_id})")
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:range_sample, %Sample{} = sample}, state) do
    RosBridge.ZenohClient.publish(state.topic, Range, range(sample, state))

    {:noreply, state}
  end

  @doc "The `Range` for `sample`. Pure."
  def range(%Sample{range: {min_range_m, max_range_m}} = sample, state) do
    %Range{
      header: %Header{
        stamp: Timing.stamp_from_system_time(sample.measured_at),
        frame_id: state.frame_id
      },
      radiation_type: state.radiation_type,
      field_of_view: sample.field_of_view,
      min_range: min_range_m,
      max_range: max_range_m,
      range:
        case sample.distance do
          :below_range -> :neg_infinity
          :beyond_range when state.beyond_range == :max_range -> max_range_m
          :beyond_range -> :infinity
          metres -> metres
        end
    }
  end
end
