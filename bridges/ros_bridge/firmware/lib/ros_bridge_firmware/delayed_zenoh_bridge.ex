defmodule ROSBridgeFirmware.DelayedZenohBridge do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(args) do
    Process.send_after(self(), {:start_daemon, args}, 10_000)
    {:ok, nil}
  end

  @impl true
  def handle_info({:start_daemon, args}, _state) do
    {:ok, pid} = apply(MuonTrap.Daemon, :start_link, args)
    {:noreply, pid}
  end
end
