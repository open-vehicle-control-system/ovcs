defmodule VmsCore.NetworkInterfaces do
  @moduledoc """
  The CAN network interfaces Cantastic is configured with, and their
  `ip` link statistics, for the VMS API.
  """
  use GenServer
  alias Cantastic.ConfigurationStore

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    network_interfaces =
      ConfigurationStore.networks()
      |> Enum.map(fn network_interface ->
        spi_interface_name =
          case network_interface.labels do
            [spi_interface: spi_interface_name] -> spi_interface_name
            _ -> nil
          end

        network_interface
        |> Map.put(:statistics, %{})
        |> Map.put(:spi_interface_name, spi_interface_name)
      end)

    {:ok, %{network_interfaces: network_interfaces}}
  end

  @impl GenServer
  def handle_call(:network_interfaces, _from, state) do
    network_interfaces_with_statistics =
      state.network_interfaces
      |> Enum.map(fn network_interface ->
        # `-s` twice adds the detailed error counters.
        {statistics_as_json, 0} =
          System.cmd("ip", [
            "--json",
            "-details",
            "-s",
            "-s",
            "address",
            "show",
            network_interface.interface
          ])

        {:ok, [statistics]} = Jason.decode(statistics_as_json)
        %{network_interface | statistics: statistics}
      end)

    {:reply, {:ok, network_interfaces_with_statistics}, state}
  end

  @doc "Each network interface with its current statistics."
  def network_interfaces do
    GenServer.call(__MODULE__, :network_interfaces)
  end
end
