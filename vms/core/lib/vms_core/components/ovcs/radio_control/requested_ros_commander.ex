defmodule VmsCore.Components.OVCS.RadioControl.RequestedRosCommander do
  @moduledoc """
    Pick which ROS commander drives, when ROS has authority.

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
  the vehicle", never "the planner gets it unasked".

  > #### The endpoints are unverified {: .warning}
  >
  > 1000/2000 is the convention every other channel here uses, not a
  > measurement -- the transmitter was off when this was written. Before
  > the first planner drive, confirm with `candump` that channel 5 of
  > `0x2A1` actually reaches ~2000 in the up position. A switch that
  > tops out at 1800 sits outside `@channel_margin` and reads as
  > `:teleop` forever, silently.
  """

  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias OvcsBus, as: Bus

  @loop_period 10
  @default_value 1000
  @value_mapping %{1000 => :teleop, 2000 => :autonomous}
  @default_requested_ros_commander @value_mapping[@default_value]
  # RC PWM channels jitter and rarely sit exactly on 1000/2000, so match
  # any value within this margin of a known position before falling back.
  @channel_margin 100

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
       raw_channel: @default_value,
       requested_ros_commander: @default_requested_ros_commander
     }}
  end

  @impl true
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
      Enum.find_value(@value_mapping, @default_requested_ros_commander, fn {value, commander} ->
        if abs(state.raw_channel - value) <= @channel_margin, do: commander
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
