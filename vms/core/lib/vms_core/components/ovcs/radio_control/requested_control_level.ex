defmodule VmsCore.Components.OVCS.RadioControl.RequestedControlLevel do
  @moduledoc """
  Control level requested from a three-position radio control switch:
  broadcasts `:requested_control_level`.

  This is the authority switch: it says *who* commands the vehicle, and
  nothing more.

      1000 -> :manual   nothing commands it, or the vehicle's own pedals
      1500 -> :radio     the transmitter
      2000 -> :ros       the ROS bridge

  `:ros` deliberately does not mean "autonomous". A human on a gamepad
  and a planner both reach the VMS through the ROS bridge -- same
  topics, same CAN frames -- so which of them is driving is a separate
  question, answered on a separate channel by
  `VmsCore.Components.OVCS.RadioControl.RequestedRosCommander`.

  This only *requests* a level. `VmsCore.Managers.ControlLevel` decides,
  and refuses moves that are unsafe (in motion, not ready to drive, or
  while a fault has forced a lower level).
  """

  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias OvcsBus, as: Bus

  @loop_period_ms 10
  @channels_per_frame 4
  @default_raw_channel 1000
  @raw_channel_positions %{1000 => :manual, 1500 => :radio, 2000 => :ros}
  @default_requested_control_level @raw_channel_positions[@default_raw_channel]
  # RC PWM channels jitter and rarely sit exactly on 1000/1500/2000, so match
  # any value within this margin of a known position before falling back.
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
       requested_control_level: @default_requested_control_level
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> compute_requested_control_level()
      |> emit()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.channel_frame_name do
    raw_channel = signals[state.channel_name].value
    {:noreply, %{state | raw_channel: raw_channel}}
  end

  defp compute_requested_control_level(state) do
    requested_control_level =
      Enum.find_value(@raw_channel_positions, @default_requested_control_level, fn
        {position, level} ->
          if abs(state.raw_channel - position) <= @channel_margin, do: level
      end)

    %{state | requested_control_level: requested_control_level}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_control_level,
      value: state.requested_control_level,
      source: __MODULE__
    })

    state
  end
end
