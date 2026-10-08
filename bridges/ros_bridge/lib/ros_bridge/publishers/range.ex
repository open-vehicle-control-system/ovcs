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
  """
  use GenServer
  require Logger

  alias OvcsDrivers.Rangefinder.Sample
  alias Ros2.BuiltinInterfaces.Msg.Time
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
      radiation_type: Keyword.get(opts, :radiation_type, :ultrasound)
    }

    driver.register_listener(Keyword.fetch!(opts, :name), self())
    Logger.info("#{__MODULE__} publishing #{state.topic} (frame #{state.frame_id})")
    {:ok, state}
  end

  @impl true
  def handle_cast({:range_sample, %Sample{} = sample}, state) do
    RosBridge.ZenohClient.publish(state.topic, Range, range(sample, state))

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

  defp time(system_ns),
    do: %Time{sec: div(system_ns, 1_000_000_000), nanosec: rem(system_ns, 1_000_000_000)}
end
