defmodule VmsCore.Components.OVCS.RadioControl.RequestedControlLevel do
  @moduledoc """
    Control control level based on radio control's input
  """

  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias VmsCore.Bus

  @loop_period 10
  @default_value 1000
  @value_mapping %{1000 => :manual, 1500 => :radio, 2000 => :autonomous}
  @default_requested_control_level @value_mapping[@default_value]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{radio_control_channel: radio_control_channel}) do
    channel_frame_index = case radio_control_channel do
      channel when channel < 5 -> 0
      _ -> 1
    end
    channel_frame_name = "radio_control_channels#{channel_frame_index}"
    :ok = Receiver.subscribe(self(), :ovcs, channel_frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      channel_frame_name: channel_frame_name,
      channel_name: "channel#{radio_control_channel}",
      raw_channel: @default_value,
      requested_control_level:  @default_requested_control_level
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_requested_control_level()
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state) when name == state.channel_frame_name do
    raw_channel = signals[state.channel_name].value
    {:noreply, %{state | raw_channel: raw_channel}}
  end

  defp compute_requested_control_level(state) do
    requested_control_level = @value_mapping[state.raw_channel] || @default_requested_control_level
    %{state | requested_control_level: requested_control_level}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_control_level, value: state.requested_control_level, source: __MODULE__})
    state
  end
end
