defmodule VmsCore.Components.OVCS.RadioControl.Direction do
  @moduledoc """
  Direction requested from a two-position radio control switch:
  broadcasts `:requested_direction`, `:forward` or `:backward`.
  """

  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias OvcsBus, as: Bus

  @loop_period_ms 10
  @channels_per_frame 4
  @default_raw_channel 1000
  @raw_channel_positions %{1000 => :forward, 2000 => :backward}
  @default_direction @raw_channel_positions[@default_raw_channel]
  # RC PWM channels jitter and rarely sit exactly on 1000/2000, so match any
  # value within this margin of a known position before falling back.
  @channel_margin 100

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(%{radio_control_channel: radio_control_channel}) do
    channel_frame_index = if radio_control_channel <= @channels_per_frame, do: 0, else: 1

    channel_frame_name = "radio_control_channels#{channel_frame_index}"
    :ok = Receiver.subscribe(self(), :ovcs, channel_frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       loop_timer: timer,
       channel_frame_name: channel_frame_name,
       channel_name: "channel#{radio_control_channel}",
       raw_channel: @default_raw_channel,
       requested_direction: @default_direction
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> compute_direction()
      |> emit()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.channel_frame_name do
    raw_channel = signals[state.channel_name].value
    {:noreply, %{state | raw_channel: raw_channel}}
  end

  defp compute_direction(state) do
    direction =
      Enum.find_value(@raw_channel_positions, @default_direction, fn {position, direction} ->
        if abs(state.raw_channel - position) <= @channel_margin, do: direction
      end)

    %{state | requested_direction: direction}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_direction,
      value: state.requested_direction,
      source: __MODULE__
    })

    state
  end
end
