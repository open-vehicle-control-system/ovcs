defmodule RadioControlBridge.MavlinkForwarder.State do
  defstruct []
end

defmodule RadioControlBridge.MavlinkForwarder do
  @moduledoc """
  Listens to ExpressLRS MAVLink messages and re-emits the 8 RC
  channels on the OVCS CAN bus as two `radio_control_channels`
  frames (channels 1–4 and 5–8).
  """
  alias RadioControlBridge.MavlinkForwarder.State
  alias Cantastic.Emitter

  require Logger
  use GenServer

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}…")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = ExpressLrs.Mavlink.Interpreter.register_listener(self())

    :ok =
      Emitter.configure(:ovcs, "radio_control_channels0", %{
        parameters_builder_function: :default,
        initial_data: %{
          "channel1" => 0,
          "channel2" => 0,
          "channel3" => 0,
          "channel4" => 0
        },
        enable: true
      })

    :ok =
      Emitter.configure(:ovcs, "radio_control_channels1", %{
        parameters_builder_function: :default,
        initial_data: %{
          "channel5" => 0,
          "channel6" => 0,
          "channel7" => 0,
          "channel8" => 0
        },
        enable: true
      })

    {:ok, %State{}}
  end

  @impl true
  def handle_cast({:mavlink_message, %{name: "RC_CHANNELS_OVERRIDE"} = msg}, state) do
    channels =
      Enum.reduce(msg.base_fields, %{}, fn field, acc ->
        Map.put(acc, field.name, field.value)
      end)

    :ok =
      Emitter.update(:ovcs, "radio_control_channels0", fn data ->
        %{
          data
          | "channel1" => channels["chan1_raw"],
            "channel2" => channels["chan2_raw"],
            "channel3" => channels["chan3_raw"],
            "channel4" => channels["chan4_raw"]
        }
      end)

    :ok =
      Emitter.update(:ovcs, "radio_control_channels1", fn data ->
        %{
          data
          | "channel5" => channels["chan5_raw"],
            "channel6" => channels["chan6_raw"],
            "channel7" => channels["chan7_raw"],
            "channel8" => channels["chan8_raw"]
        }
      end)

    {:noreply, state}
  end

  def handle_cast({:mavlink_message, _other}, state), do: {:noreply, state}
end
