defmodule VmsCore.Components.OVCS.RadioControl.Throttle do
  @moduledoc """
    Control throttle based on radio control's input
  """
  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias Decimal, as: D
  alias OvcsBus, as: Bus

  @loop_period 10
  @zero D.new(0)
  @min_value 1000
  @center_value 1500
  @max_value 2000
  @range 500
  @tolerated_drift 200
  # 25 raw counts of the 500-count range. Sized for a *continuous*
  # control at rest, which drifts by roughly 5-20 counts -- deliberately
  # not `RequestedControlLevel`'s 100, which is sized to snap a discrete
  # switch onto one of three endpoints and would swallow a fifth of the
  # brake travel.
  #
  # NOTE: this changes hardware-validated OVCS1 behaviour. Taking over
  # from ROS by pulling the trigger now needs 5% of reverse travel
  # rather than any negative reading at all.
  @breaking_threshold D.new("-0.05")

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{radio_control_channel: radio_control_channel}) do
    channel_frame_index =
      case radio_control_channel do
        channel when channel < 5 -> 0
        _ -> 1
      end

    channel_frame_name = "radio_control_channels#{channel_frame_index}"
    :ok = Receiver.subscribe(self(), :ovcs, channel_frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       channel_frame_name: channel_frame_name,
       channel_name: "channel#{radio_control_channel}",
       raw_channel: @center_value,
       requested_throttle: @zero,
       radio_breaking: false
     }}
  end

  @impl true
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
      raw_channel > @max_value + @tolerated_drift ->
        {:noreply, state}

      raw_channel < @min_value - @tolerated_drift ->
        {:noreply, state}

      true ->
        sanitized_raw_channel = raw_channel |> D.min(@max_value) |> D.max(@min_value)
        {:noreply, %{state | raw_channel: sanitized_raw_channel}}
    end
  end

  defp compute_throttle(state) do
    requested_throttle = state.raw_channel |> D.sub(@center_value) |> D.div(@range)

    # Two things this deliberately does not do.
    #
    # It does not read `state.requested_throttle`, which is the
    # *previous* tick's value: reporting a brake one 10 ms loop late is
    # pointless when the whole purpose is a takeover.
    #
    # And it does not compare against zero. `radio_breaking` drops the
    # control level and latches `forced_control_level`, so a trigger
    # trimmed a hair below centre -- 1495 raw, i.e. -0.01 -- used to
    # make `:ros` unreachable with no way back but re-centring the trim,
    # and re-triggered the moment the operator switched back up.
    radio_breaking = requested_throttle |> D.lt?(@breaking_threshold)

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
