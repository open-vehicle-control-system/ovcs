defmodule VmsCore.Components.OVCS.RadioControl.Steering do
  @moduledoc """
  Steering requested from a radio control stick: broadcasts
  `:requested_steering`, normalised to [-1, 1] around the channel's centre.
  """
  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias Decimal, as: D
  alias OvcsBus, as: Bus

  @loop_period_ms 10
  @zero D.new(0)
  @channels_per_frame 4
  @min_raw_channel 1000
  @center_raw_channel 1500
  @max_raw_channel 2000
  @half_travel @max_raw_channel - @center_raw_channel
  # A reading further than this outside the endpoints is a glitch and is
  # dropped; a nearer one is clamped.
  @tolerated_drift 200

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
       raw_channel: @center_raw_channel,
       requested_steering: @zero
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> compute_steering()
      |> emit()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.channel_frame_name do
    raw_channel = signals[state.channel_name].value

    cond do
      raw_channel > @max_raw_channel + @tolerated_drift ->
        {:noreply, state}

      raw_channel < @min_raw_channel - @tolerated_drift ->
        {:noreply, state}

      true ->
        sanitized_raw_channel =
          raw_channel |> D.min(@max_raw_channel) |> D.max(@min_raw_channel)

        {:noreply, %{state | raw_channel: sanitized_raw_channel}}
    end
  end

  defp compute_steering(state) do
    requested_steering =
      state.raw_channel |> D.sub(@center_raw_channel) |> D.div(@half_travel)

    %{state | requested_steering: requested_steering}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_steering,
      value: state.requested_steering,
      source: __MODULE__
    })

    state
  end
end
