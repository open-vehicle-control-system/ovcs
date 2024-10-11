defmodule VmsCore.NetworkInterfaces do
  use GenServer
  require Logger
  alias Cantastic.ConfigurationStore

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    network_interfaces = ConfigurationStore.networks() |> Enum.map(fn (network_interface) ->
      spi_interface_name = case network_interface.labels do
        [spi_interface: spi_interface_name] -> spi_interface_name
        _ -> nil
      end
      network_interface
      |> Map.put(:statistics, %{})
      |> Map.put(:spi_interface_name, spi_interface_name)
    end)

    {:ok, %{network_interfaces: network_interfaces}}
  end

  @impl true
  def handle_call(:network_interfaces, _from, state) do
    result = state.network_interfaces |> Enum.map(fn (network_interface) ->
      {statistics_as_json, 0} = System.cmd("ip", ["--json", "-details", "-s", "-s", "address", "show", network_interface.interface])
      {:ok, [statistics]}     = Jason.decode(statistics_as_json)
      %{network_interface | statistics: statistics}
    end)
    {:reply, {:ok, result}, state}
  end

  def network_interfaces do
    GenServer.call(__MODULE__, :network_interfaces)
  end
end
