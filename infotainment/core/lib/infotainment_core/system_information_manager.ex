defmodule InfotainmentCore.SystemInformationManager do
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def system_information() do
    GenServer.call(__MODULE__, :system_information)
  end

  @impl true
  def init([]) do
    {:ok,
      %{
        data: %{}
      }
    }
  end

  @impl true
  def handle_call(:system_information, _from, state) do
    {:reply, state |> Map.put(:data, local_ip_addresses()), state}
  end

  defp local_ip_addresses() do
    {addresses, 0} = System.cmd("ip", ["--json", "address"])
    {:ok, json} = JSON.decode(addresses)

    Enum.filter(json, fn interface ->
      interface["addr_info"] != [] && interface["ifname"] != "lo"
    end) |> Enum.map(
      fn interface ->
        Enum.filter interface["addr_info"], fn address ->
          address["family"] == "inet"
        end
      end
    ) |> List.flatten |> Enum.map(
      fn local_interface ->
        %{
          id: local_interface["label"],
          name: local_interface["label"],
          label: "Network interface",
          value: local_interface["local"],
          unit: nil
        }
      end
    )
  end
end
