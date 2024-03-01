defmodule VmsCore.NetworkInterfacesMonitor do
  use GenServer
  require Logger

  @interface_status_refresh_interval_ms 500

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    schedule_worker()
    {:ok,
    %{
        clients: [],
        interfaces: %{}
      }
    }
  end

  @impl true
  def handle_cast({:subscribe, client}, state) do
    {:noreply, %{state | clients: [client | state.clients]}}
  end

  def subscribe(client) do
    GenServer.cast(__MODULE__, {:subscribe, client})
  end

  @impl true
  def handle_info(:update_interfaces_status, state) do
    schedule_worker()
    {interfaces_as_json, 0} = System.cmd("ip", ["--json", "-details", "-statistics", "address", "show"])
    {:ok, interfaces}       = JSON.decode(interfaces_as_json)
    state = Map.put(state, :interfaces, interfaces)
    state.clients |> Enum.each(fn (client) ->
      GenServer.cast(client, {:interfaces_status_updated, state.interfaces})
    end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:subscribe, client}, state) do
    {:noreply, %{state | clients: [client | state.clients]}}
  end

  defp schedule_worker() do
    Process.send_after(self(), :update_interfaces_status, @interface_status_refresh_interval_ms)
  end
end
