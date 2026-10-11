defmodule VmsCore.Components.OVCS.RadioControl.RequestedRosCommander do
  @moduledoc """
  ROS commander requested from a two-position radio control switch:
  broadcasts `:requested_ros_commander`, which picks the ROS node that
  drives when ROS has authority.

  This is the second of two orthogonal switches, and it answers a
  different question from `RequestedControlLevel`:

      RequestedControlLevel   who has authority   :manual / :radio / :ros
      RequestedRosCommander   which ROS node      :teleop / :autonomous

  They are separate because a human on a gamepad and a planner are both
  "ROS" as far as the VMS is concerned -- same topics, same CAN frames,
  same authority -- but they are not the same risk. Folding them into
  one four-position switch would tie "hand the vehicle to ROS" and
  "let the planner decide where to go" to a single throw.

  Only `Managers.ControlLevel` acts on this. Off the `:ros` level it is
  recorded and ignored, so flipping the switch in `:manual` does
  nothing at all -- which is what makes it safe to set up on the bench.

  ## Positions

  A two-position switch, using the same PWM endpoints as the authority
  switch so both read the same way on a transmitter:

      1000 -> :teleop        the gamepad, via /joy
      2000 -> :autonomous    the planner, via /cmd_vel_nav

  Anything else -- an unmapped middle position, a channel nobody
  transmits, a receiver in failsafe -- falls back to `:teleop`. The
  fallback is the whole reason the mapping is written this way round:
  the failure mode of a mis-set endpoint is "the planner does not get
  the vehicle", never "the planner gets it unasked". A switch whose up
  position does not reach within `@channel_margin` of 2000 therefore
  reads as `:teleop`, silently: check its endpoint on the CAN bus
  before relying on it.
  """

  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias OvcsBus, as: Bus

  @loop_period_ms 10
  @channels_per_frame 4
  @default_raw_channel 1000
  @raw_channel_positions %{1000 => :teleop, 2000 => :autonomous}
  @default_requested_ros_commander @raw_channel_positions[@default_raw_channel]
  # RC PWM channels jitter and rarely sit exactly on 1000/2000, so match
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
       requested_ros_commander: @default_requested_ros_commander
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> compute_requested_ros_commander()
      |> emit()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.channel_frame_name do
    raw_channel = signals[state.channel_name].value
    {:noreply, %{state | raw_channel: raw_channel}}
  end

  defp compute_requested_ros_commander(state) do
    requested_ros_commander =
      Enum.find_value(@raw_channel_positions, @default_requested_ros_commander, fn
        {position, commander} ->
          if abs(state.raw_channel - position) <= @channel_margin, do: commander
      end)

    %{state | requested_ros_commander: requested_ros_commander}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_ros_commander,
      value: state.requested_ros_commander,
      source: __MODULE__
    })

    state
  end
end
