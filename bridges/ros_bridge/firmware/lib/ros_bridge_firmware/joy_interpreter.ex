defmodule ROSBridgeFirmware.JoyInterpreter.State do
  defstruct []
end

defmodule ROSBridgeFirmware.JoyInterpreter do
  alias ROSBridgeFirmware.JoyInterpreter.State
  alias Cantastic.Emitter

  require Logger
  alias Decimal, as: D
  use GenServer

  @max_value 2**31 - 1

  @impl true
  def init(_) do
    :ok = Emitter.configure(:ovcs, "ros_control0", %{
      parameters_builder_function: :default,
      initial_data: %{
        "control_level" => "joy",
        "direction" => "forward"
      },
      enable: true
    })
    :ok = Emitter.configure(:ovcs, "ros_control1", %{
      parameters_builder_function: :default,
      initial_data: %{
        "throttle" => D.new(0),
        "steering" => D.new(0)
      },
      enable: true
    })
    :ok = ZenohMQTTRos2.Dispatcher.start_subscriber("0/joy/")
    {:ok, %State{}}
  end

  @spec start_link(nil) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def handle_info({:mqtt_message, {topic, message}}, state) do
    # Logger.debug("#{__MODULE__} #{inspect message}")
    :ok = Emitter.update(:ovcs, "ros_control1", fn (data) ->
      %{data |
        "steering" => message.axes |> Enum.at(0) |> D.from_float |> D.mult(-@max_value),
        "throttle" => message.axes |> Enum.at(1) |> D.from_float |> D.mult(@max_value)
      }
    end)
    {:noreply, state}
  end
end
