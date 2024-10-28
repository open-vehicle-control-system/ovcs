defmodule MdnsLite.ResponderSupervisor do
  @moduledoc false
  use DynamicSupervisor

  alias MdnsLite.Responder

  @spec start_link(any) :: GenServer.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec start_child(String.t(), :inet.ip_address()) :: DynamicSupervisor.on_start_child()
  def start_child(ifname, address) do
    DynamicSupervisor.start_child(__MODULE__, {Responder, {ifname, address}})
  end

  @spec stop_child(String.t(), :inet.ip_address()) :: :ok
  def stop_child(ifname, address) do
    Responder.stop_server(ifname, address)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
