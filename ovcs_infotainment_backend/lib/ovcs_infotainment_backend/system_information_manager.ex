defmodule OvcsInfotainmentBackend.SystemInformationManager do
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def information() do
    GenServer.call(__MODULE__, :get_system_information)
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
  def handle_call(:get_system_information, _from, state) do
    {result, 0} = System.cmd("ip", ["route","list","default"])
    default_if = Regex.scan(~r/.*dev (.*) .*/U, result, capture: :all_but_first) |> List.first |> List.first |> String.to_charlist
    {:ok, ifs} = :inet.getifaddrs
    {_if, attrs} = List.keyfind(ifs, default_if, 0)
    {:addr, ip} = List.keyfind(attrs, :addr, 0)
    {a,b,c,d} = ip
    ip_as_string = "#{a}.#{b}.#{c}.#{d}"
    {:reply, state |> Map.put(:data, %{name: "ipAddress", value: ip_as_string, unit: ""}), state}
  end
end
