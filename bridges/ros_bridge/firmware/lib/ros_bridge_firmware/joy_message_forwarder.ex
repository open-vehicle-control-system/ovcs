defmodule ROSBridgeFirmware.JoyMessageForwarder.State do
  defstruct []
end

defmodule ROSBridgeFirmware.JoyMessageForwarder do
  alias ROSBridgeFirmware.JoyMessageForwarder.State
  alias Cantastic.Emitter

  require Logger
  use GenServer

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
        "throttle" => 0,
        "steering" => 0
      },
      enable: true
    })
    {:ok, %State{}}
  end

  @spec start_link(nil) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug "Starting #{__MODULE__}..."
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end
end
