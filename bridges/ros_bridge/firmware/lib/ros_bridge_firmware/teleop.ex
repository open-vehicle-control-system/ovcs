defmodule ROSBridgeFirmware.Teleop do
  use GenServer
  require Logger

  @orchestrator_timer 500

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{orchestrator: orchestrator} = _args) do
    unless orchestrator == nil do
      orchestrator.start_link([])
      wait_until_orchestrator_says_its_safe(orchestrator)
    end
    :ok = Rclex.start_node("teleop")
    :ok = Rclex.start_subscription(&velocity_callback/1, Rclex.Pkgs.GeometryMsgs.Msg.Twist, "/cmd_vel", "teleop")
    {:ok, %{}}
  end

  defp velocity_callback(message) do
    Logger.debug("Received msg: #{inspect(message)}")
  end

  defp wait_until_orchestrator_says_its_safe(orchestrator) do
    if orchestrator.safe?() == {:ok, false} do
      Logger.debug("#{__MODULE__} waiting for orchestrator to say it's safe to run...")
      Process.sleep(@orchestrator_timer)
      wait_until_orchestrator_says_its_safe(orchestrator)
    end
  end
end
