defmodule ROSBridgeFirmware.NetworkWatcher do
  use GenServer

  require Logger

  @timer 500

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    start_timer()
    {:ok, %{
      status: :disconnected
    }}
  end

  @impl true
  def handle_call(:safe, _from, state) do
    case state.status do
      :connected ->
        {:reply, {:ok, true}, state}
      :disconnected ->
        {:reply, {:ok, false}, state}
    end
  end

  defp start_timer do
    {:ok, _timer} = :timer.send_interval(@timer, :loop)
  end

  def safe? do
    GenServer.call(__MODULE__, :safe)
  end

  @impl true
  def handle_info(:loop, state) do
    {result, 0} = System.cmd("ip", ["route", "show", "default"])
    gateway = result |> String.split("\n") |> Enum.flat_map(&String.split/1) |> Enum.at(2)
    case gateway do
      nil ->
        Logger.warning("Network disconnected...")
        state = %{state | status: :disconnected}
        {:noreply, state}
      _ ->
        if(state.status == :disconnected) do
          Logger.info("Network connected")
        end
        state = %{state | status: :connected}
        {:noreply, state}
    end

  end
end
