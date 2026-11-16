defmodule VisionCore.Inference.Watch do
  @moduledoc """
  Stands in a unit's supervisor for a backend the unit shares with
  others, such as `VisionCore.Hailo`, where a unit with a backend of its
  own starts it: it runs while that backend runs, and exits when it goes
  down. The unit's `:rest_for_one` supervisor then restarts its pipeline,
  which waited for a reply the restarted backend will never send, as it
  does when a backend of its own restarts.

  It fails to start while the backend is not running, which leaves the
  unit down, saying so.

  ## Options

    * `:server` — the backend's registered name (required).
    * `:unit` — the unit watching it, for the message (required).
  """
  use GenServer

  @doc "Starts watching `:server`; see the module doc for `opts`."
  def start_link(opts) do
    server = Keyword.fetch!(opts, :server)
    unit = Keyword.fetch!(opts, :unit)

    case GenServer.whereis(server) do
      nil ->
        {:error, "the unit #{inspect(unit)} has no backend: #{inspect(server)} is not running"}

      pid ->
        GenServer.start_link(__MODULE__, {server, pid})
    end
  end

  @impl GenServer
  def init({server, pid}) do
    Process.monitor(pid)
    {:ok, server}
  end

  @impl GenServer
  def handle_info({:DOWN, _reference, :process, _pid, _reason}, server),
    do: {:stop, {:backend_down, server}, server}
end
