defmodule CotBridge.Publisher do
  @moduledoc """
  Periodically renders the freshest tracked position as a CoT event
  and pushes it to the TAK server.

  A tick is skipped when no position has been seen yet, or when the
  freshest one is older than `:position_max_age_ms` — the last
  event's stale time then does its job and the marker fades on the
  WebTAK side rather than freezing at a phantom location.
  """
  use GenServer

  require Logger

  alias CotBridge.{Cot, PositionTracker, TakConnection}

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    {:ok, timer} = :timer.send_interval(config.publish_interval_ms, :publish)

    Logger.info(
      "#{__MODULE__} publishing \"#{config.callsign}\" (#{config.uid}) " <>
        "every #{config.publish_interval_ms}ms"
    )

    {:ok, %{config: config, loop_timer: timer}}
  end

  @impl true
  def handle_info(:publish, %{config: config} = state) do
    case PositionTracker.latest() do
      {:ok, position, age_ms} when age_ms <= config.position_max_age_ms ->
        position
        |> Cot.position_event(
          uid: config.uid,
          callsign: config.callsign,
          cot_type: config.cot_type,
          team: config.team,
          role: config.role,
          stale_after_s: config.stale_after_s
        )
        |> TakConnection.send_event()

      _no_fresh_position ->
        :ok
    end

    {:noreply, state}
  end
end
