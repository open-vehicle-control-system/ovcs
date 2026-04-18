defmodule InfotainmentCore.TimeSettings do
  @moduledoc """
    GenServer managing time display settings (timezone, time format, date format).
    Settings are persisted to SQLite so they survive restarts.
    Exposes `status/0` and `trigger_action/2` for the composable metrics/actions system.
  """
  use GenServer

  alias InfotainmentCore.Repo
  alias InfotainmentCore.Models.TimeSetting

  @defaults %{
    timezone: "UTC",
    time_format: "24h",
    date_format: "DD/MM/YYYY"
  }

  def start_link(_args) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    settings = load_or_create_settings()

    {:ok,
     %{
       timezone: settings.timezone,
       time_format: settings.time_format,
       date_format: settings.date_format
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:set_timezone, timezone}, _from, state) do
    state = %{state | timezone: timezone}
    persist(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_time_format, time_format}, _from, state) do
    state = %{state | time_format: time_format}
    persist(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_date_format, date_format}, _from, state) do
    state = %{state | date_format: date_format}
    persist(state)
    {:reply, :ok, state}
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def trigger_action("set_timezone", %{"timezone" => timezone}) do
    GenServer.call(__MODULE__, {:set_timezone, timezone})
  end

  def trigger_action("set_time_format", %{"time_format" => time_format}) do
    GenServer.call(__MODULE__, {:set_time_format, time_format})
  end

  def trigger_action("set_date_format", %{"date_format" => date_format}) do
    GenServer.call(__MODULE__, {:set_date_format, date_format})
  end

  defp load_or_create_settings do
    case Repo.all(TimeSetting) do
      [settings | _] ->
        settings

      [] ->
        %TimeSetting{
          timezone: @defaults.timezone,
          time_format: @defaults.time_format,
          date_format: @defaults.date_format
        }
        |> Repo.insert!()
    end
  end

  defp persist(state) do
    case Repo.all(TimeSetting) do
      [settings | _] ->
        settings
        |> Ecto.Changeset.change(%{
          timezone: state.timezone,
          time_format: state.time_format,
          date_format: state.date_format
        })
        |> Repo.update!()

      [] ->
        %TimeSetting{
          timezone: state.timezone,
          time_format: state.time_format,
          date_format: state.date_format
        }
        |> Repo.insert!()
    end
  end
end
