defmodule ROSBridgeFirmware.Teleop.State do
  defstruct []
end

defmodule ROSBridgeFirmware.Teleop do
  use GenServer
  require Logger
  alias ROSBridgeFirmware.Teleop.State
  alias Cantastic.Emitter

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

    :ok = Emitter.configure(:ovcs, "ros_control", %{
      parameters_builder_function: :default,
      initial_data: %{
        "linear" => 0,
        "angular" => 0
      },
      enable: true
    })

    {:ok, %State{}}
  end

  defp velocity_callback(message) do
    linear_speed = message.linear.x
    angular_speed = message.angular.z
    :ok = Emitter.update(:ovcs, "ros_control", fn (data) ->
      %{data |
        "linear" => linear_speed,
        "angular" => angular_speed
      }
    end)
  end

  defp wait_until_orchestrator_says_its_safe(orchestrator) do
    if orchestrator.safe?() == {:ok, false} do
      Logger.debug("#{__MODULE__} waiting for orchestrator to say it's safe to run...")
      Process.sleep(@orchestrator_timer)
      wait_until_orchestrator_says_its_safe(orchestrator)
    end
  end
end
