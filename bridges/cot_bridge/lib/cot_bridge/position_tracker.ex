defmodule CotBridge.PositionTracker do
  @moduledoc """
  Combines the CoT parameters from the vehicle's bus messages.

  Nothing about the vehicle guarantees which component owns which
  parameter — a GNSS receiver may or may not report altitude or a
  usable course, speed usually belongs to the ABS/drivetrain driver,
  a compass/IMU component could own the heading. So every parameter
  follows the OVCS source-module convention: the vehicle names the
  module whose messages feed it, and the tracker only accepts a
  message when both its `:name` and `:source` match.

  | Parameter | Bus message | Config knob |
  |-----------|-------------|-------------|
  | position (map: lat/lon + fix metadata) | `:vehicle_position` | `:position_source` |
  | altitude (m) | `:altitude` | `:altitude_source` |
  | speed (km/h) | `:speed` | `:speed_source` |
  | heading (degrees) | `:heading` | `:heading_source` |

  `latest/0` merges the parameters into one position map, dropping
  any value older than `:source_max_age_ms` so a stalled source
  degrades to "unknown" rather than freezing. Without a fresh
  position nothing can be published at all — the other parameters
  only decorate it.
  """
  use GenServer

  require Logger

  alias OvcsBus, as: Bus

  @message_parameters %{
    vehicle_position: :position,
    altitude: :altitude,
    speed: :speed,
    heading: :heading
  }

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Latest merged position: `{:ok, position, age_ms}`, or `:no_position` before the first fix."
  def latest do
    GenServer.call(__MODULE__, :latest)
  end

  @impl true
  def init(config) do
    :ok = Bus.subscribe("messages")

    sources = %{
      position: config.position_source,
      altitude: config.altitude_source,
      speed: config.speed_source,
      heading: config.heading_source
    }

    if is_nil(sources.position) do
      Logger.warning(
        "#{__MODULE__} has no :position_source configured — nothing will be published"
      )
    end

    {:ok, %{sources: sources, max_age_ms: config.source_max_age_ms, values: %{}}}
  end

  @impl true
  def handle_info(%Bus.Message{name: name, value: value, source: source}, state) do
    parameter = @message_parameters[name]

    if parameter && !is_nil(source) && source == state.sources[parameter] do
      values = Map.put(state.values, parameter, %{value: value, received_at: now()})
      {:noreply, %{state | values: values}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:latest, _from, state) do
    case state.values[:position] do
      nil ->
        {:reply, :no_position, state}

      %{value: position, received_at: received_at} ->
        merged =
          position
          |> Map.put(:altitude, fresh_value(state, :altitude))
          |> Map.put(:speed, fresh_value(state, :speed))
          |> Map.put(:heading, fresh_value(state, :heading))

        {:reply, {:ok, merged, now() - received_at}, state}
    end
  end

  defp fresh_value(state, parameter) do
    with %{value: value, received_at: received_at} <- state.values[parameter],
         true <- now() - received_at <= state.max_age_ms do
      value
    else
      _ -> nil
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
