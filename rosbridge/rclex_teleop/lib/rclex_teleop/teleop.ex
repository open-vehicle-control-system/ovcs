defmodule RclexTeleop.Teleop do
  use GenServer
  require Logger


  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :ok = Rclex.start_node("teleop")
    :ok = Rclex.start_subscription(&velocity_callback/1, Rclex.Pkgs.GeometryMsgs.Msg.Twist, "/cmd_vel", "teleop")
    {:ok, %{}}
  end

  defp velocity_callback(message) do
    Logger.debug("#{__MODULE__} receive msg: #{inspect(message)}")
  end

end
