defmodule Cantastic.Socketcand do
  use GenServer
  require Logger

  @impl true
  def init(_) do
    if Cantastic.ConfigurationStore.enable_socketcand() do
      start_socket_can_deamon()
    end
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(:start_socket_can_deamon, state) do
    networks = Cantastic.ConfigurationStore.networks()
    ip_interface = Cantastic.ConfigurationStore.socketcand_ip_interface()
    interfaces = networks |> Enum.map(fn(network) ->
          network.interface
        end) |> Enum.join(",")

    Task.async(fn() ->
      Logger.info("Starting socketcand for debugging purposes...")
      {output, 0} = System.cmd("socketcand", ["-i", interfaces, "-l", ip_interface])
    end)
    {:noreply, state}
  end

  defp start_socket_can_deamon do
    Process.send_after(self(), :start_socket_can_deamon, 30000)
  end
end
