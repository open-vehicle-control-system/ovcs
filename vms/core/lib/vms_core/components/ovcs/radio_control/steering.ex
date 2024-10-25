defmodule VmsCore.Components.OVCS.RadioControl.Steering do
  @moduledoc """
    Control steering based on radio control's input
  """
  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias Decimal, as: D
  alias VmsCore.Bus

  @loop_period 10
  @zero D.new(0)
  @min_value 1000
  @center_value 1500
  @max_value 2000
  @range 500

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{radio_control_channel: radio_control_channel}) do
    channel_frame_index = case radio_control_channel do
      channel when channel < 4 -> 0
      _ -> 1
    end
    channel_frame_name = "radio_control_channels#{channel_frame_index}"
    :ok = Receiver.subscribe(self(), :ovcs, channel_frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      channel_frame_name: channel_frame_name,
      channel_name: "channel#{radio_control_channel}",
      raw_channel: 0,
      requested_steering: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_steering()
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state) when name == state.channel_frame_name do
    raw_channel = signals[state.channel_name]
    {:noreply, %{state | raw_channel: raw_channel}}
  end

  defp compute_steering(state) do
    sanitized_raw_channel = state.raw_channel |> D.min(@max_value) |> D.max(@min_value)
    requested_steering    = sanitized_raw_channel |> D.sub(@center_value) |> D.div(@range)
    %{state | requested_steering: requested_steering}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_steering, value: state.requested_steering, source: __MODULE__})
    state
  end
end
