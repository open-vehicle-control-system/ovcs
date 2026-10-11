defmodule VmsCore.Components.OVCS.RadioControl.Throttle do
  @moduledoc """
  Throttle requested from a radio control trigger: broadcasts
  `:requested_throttle`, normalised to [-1, 1] around the channel's
  centre, and `:radio_breaking` while the trigger is pulled in reverse
  past `@braking_threshold`.

  `:radio_breaking` takes authority back from ROS and latches a forced
  control level in `VmsCore.Managers.ControlLevel`, so it is computed
  from the current reading, not the previous tick's, and against a
  threshold rather than zero: a trigger trimmed slightly below centre
  would otherwise make `:ros` unreachable until the trim is re-centred.
  The threshold is sized for a continuous control drifting at rest, so
  it is smaller than the margin the switch channels snap with, which
  would swallow much of the brake travel.
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
  @braking_threshold D.new("-0.05")

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
       requested_throttle: @zero,
       radio_breaking: false
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> compute_throttle()
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

  defp compute_throttle(state) do
    requested_throttle =
      state.raw_channel |> D.sub(@center_raw_channel) |> D.div(@half_travel)

    radio_breaking = requested_throttle |> D.lt?(@braking_threshold)

    %{state | requested_throttle: requested_throttle, radio_breaking: radio_breaking}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle,
      value: state.requested_throttle,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :radio_breaking,
      value: state.radio_breaking,
      source: __MODULE__
    })

    state
  end
end
