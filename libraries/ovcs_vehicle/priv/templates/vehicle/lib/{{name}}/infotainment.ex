defmodule <%= @module %>.Infotainment do
  @moduledoc """
  Infotainment-side vehicle GenServer.

  Subscribes to VMS-published CAN frames and stores the latest
  values so the infotainment UI can poll `status/0`. Extend with
  additional `handle_info({:handle_frame, …}, state)` clauses per
  frame you care about in `priv/can/infotainment.yml`.
  """
  use GenServer
  alias Cantastic.{Signal, Frame, Receiver}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, ["vms_status"])
    {:ok, %{vms_status: "UNKNOWN"}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: "vms_status", signals: signals}}, state) do
    %{"status" => %Signal{value: status}} = signals
    {:noreply, %{state | vms_status: status}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, {:ok, state}, state}

  @doc "Snapshot of the latest infotainment state (used by dashboard blocks)."
  def status, do: GenServer.call(__MODULE__, :status)
end
