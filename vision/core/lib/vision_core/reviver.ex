defmodule VisionCore.Reviver do
  @moduledoc """
  Starts again the units that are down: every `:interval_ms`, each
  child of `:supervisor` among `:units` that is not running is
  restarted.

  A unit runs under its own restart budget and is not restarted once it
  exhausts it, nor when it fails to start, so that it cannot take the
  rest of the vision core with it (`VisionCore.Components`). What made
  it fail may be gone later, as a camera plugged back in, so it is tried
  again here, on an interval long enough that a unit that keeps failing
  costs little: it logs its failure once per try.

  `VisionCore.Application` starts it last in `VisionCore.Supervisor`,
  with the components' child ids. Stop it, as
  `Supervisor.terminate_child(VisionCore.Supervisor, VisionCore.Reviver)`
  does, before stopping a unit that is to stay down.

  ## Options

    * `:supervisor` (required) — the supervisor of the units.
    * `:units` (required) — the child ids of the units.
    * `:interval_ms` (`60000`) — a positive integer.
    * `:name` (`VisionCore.Reviver`).
  """
  use GenServer
  require Logger

  @default_interval_ms 60_000

  @doc "Starts the reviver; see the module doc for `opts`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl GenServer
  def init(opts) do
    interval_ms = VisionCore.Options.integer!(opts, :interval_ms, @default_interval_ms, 1)

    state = %{
      supervisor: Keyword.fetch!(opts, :supervisor),
      units: Keyword.fetch!(opts, :units),
      interval_ms: interval_ms
    }

    Process.send_after(self(), :revive, interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:revive, state) do
    Process.send_after(self(), :revive, state.interval_ms)
    for unit <- down(state), do: revive(state.supervisor, unit)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A supervisor that does not answer, busy starting a child, is asked again at the next interval.
  defp down(state) do
    for {id, :undefined, _type, _modules} <- Supervisor.which_children(state.supervisor),
        id in state.units,
        do: id
  catch
    :exit, _reason -> []
  end

  defp revive(supervisor, unit) do
    case Supervisor.restart_child(supervisor, unit) do
      {:ok, pid} when is_pid(pid) ->
        Logger.info("#{inspect(__MODULE__)}: #{inspect(unit)} was down and runs again")

      _still_down ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
