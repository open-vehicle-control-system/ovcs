defmodule VmsCore.Components.OVCS.RadioControl.Direction do
  @moduledoc """
    Control direction based on radio control's input
  """

  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias VmsCore.Bus

  @loop_period 10
  @default_value 1000
  @value_mapping %{1000 => :forward, 2000 => :backward}
  @default_direction @value_mapping[@default_value]

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
      requested_direction:  @default_direction
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_direction()
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state) when name == state.channel_frame_name do
    raw_channel = signals[state.channel_name].value
    {:noreply, %{state | raw_channel: raw_channel}}
  end

  defp compute_direction(state) do
    direction = @value_mapping[state.raw_channel] || @default_direction
    %{state | requested_direction: direction}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_direction, value: state.requested_direction, source: __MODULE__})
    state
  end
end
