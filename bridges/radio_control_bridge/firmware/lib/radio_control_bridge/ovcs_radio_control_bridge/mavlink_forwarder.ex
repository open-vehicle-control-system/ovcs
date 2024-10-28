defmodule RadioControlBridgeFirmware.MavlinkForwarder.State do
  defstruct []
end

defmodule RadioControlBridgeFirmware.MavlinkForwarder do
  alias RadioControlBridgeFirmware.MavlinkForwarder.State
  alias Cantastic.Emitter

  require Logger
  use GenServer

  @impl true
  def init(_) do
    :ok = ExpressLrs.Mavlink.Interpreter.register_listener(self())
    :ok = Emitter.configure(:ovcs, "radio_control_channels0", %{
      parameters_builder_function: :default,
      initial_data: %{
        "channel1" => 0,
        "channel2" => 0,
        "channel3" => 0,
        "channel4" => 0,
      },
      enable: true
    })
    :ok = Emitter.configure(:ovcs, "radio_control_channels1", %{
      parameters_builder_function: :default,
      initial_data: %{
        "channel5" => 0,
        "channel6" => 0,
        "channel7" => 0,
        "channel8" => 0,
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

  @impl true
  def handle_cast({:mavlink_message, mavlink_message}, state) do
    case mavlink_message.name do
      "RC_CHANNELS_OVERRIDE" ->
        channel_values = mavlink_message.base_fields |> Enum.reduce(%{}, fn (field, channel_values) ->
          channel_values |> Map.put(field.name, field.value)
        end)
        :ok = Emitter.update(:ovcs, "radio_control_channels0", fn (data) ->
          %{data |
            "channel1" => channel_values["chan1_raw"],
            "channel2" => channel_values["chan2_raw"],
            "channel3" => channel_values["chan3_raw"],
            "channel4" => channel_values["chan4_raw"],
          }
        end)
        :ok = Emitter.update(:ovcs, "radio_control_channels1", fn (data) ->
          %{data |
            "channel5" => channel_values["chan5_raw"],
            "channel6" => channel_values["chan6_raw"],
            "channel7" => channel_values["chan7_raw"],
            "channel8" => channel_values["chan8_raw"],
          }
        end)
      _ -> mavlink_message
    end
    {:noreply, state}
  end

end
