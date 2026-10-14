defmodule VmsCore.Components.OVCS.ControlStatus do
  @moduledoc """
  Emits `control_status` (`0x60C`): who commands the vehicle and what it
  asks for, for displays off the VMS such as the ROS bridge's.

  Follows the control level manager named by
  `:selected_control_level_source`: its selected level and ROS
  commander, whether the level is forced, and the `:requested_throttle`
  and `:requested_steering` of the sources it names. A request reads
  zero while no source is named, or while the named one reports none.
  """
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias OvcsBus, as: Bus

  @loop_period_ms 50
  @frame_name "control_status"
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(%{selected_control_level_source: selected_control_level_source}) do
    :ok =
      Emitter.configure(:ovcs, @frame_name, %{
        parameters_builder_function: :default,
        initial_data: frame_data(initial_state(selected_control_level_source)),
        enable: true
      })

    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok, %{initial_state(selected_control_level_source) | loop_timer: timer}}
  end

  @doc false
  def initial_state(selected_control_level_source) do
    %{
      loop_timer: nil,
      selected_control_level_source: selected_control_level_source,
      control_level: :manual,
      ros_commander: :teleop,
      control_level_forced: false,
      requested_throttle_source: nil,
      requested_steering_source: nil,
      requested_throttle: @zero,
      requested_steering: @zero
    }
  end

  @impl GenServer
  def handle_info(:loop, state) do
    :ok = Emitter.update(:ovcs, @frame_name, fn _frame_data -> frame_data(state) end)
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: name, value: value, source: source}, state)
      when source == state.selected_control_level_source do
    {:noreply, follow_manager(state, name, value)}
  end

  def handle_info(%Bus.Message{name: :requested_throttle, value: value, source: source}, state)
      when not is_nil(source) and source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: value || @zero}}
  end

  def handle_info(%Bus.Message{name: :requested_steering, value: value, source: source}, state)
      when not is_nil(source) and source == state.requested_steering_source do
    {:noreply, %{state | requested_steering: value || @zero}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  @doc "The frame's signals for a state."
  def frame_data(state) do
    %{
      "requested_throttle" => state.requested_throttle,
      "requested_steering" => state.requested_steering,
      "control_level" => "#{state.control_level}",
      "ros_commander" => "#{state.ros_commander}",
      "control_level_forced" => state.control_level_forced
    }
  end

  defp follow_manager(state, :selected_control_level, level),
    do: %{state | control_level: level}

  defp follow_manager(state, :selected_ros_commander, commander),
    do: %{state | ros_commander: commander}

  defp follow_manager(state, :control_level_forced, forced),
    do: %{state | control_level_forced: forced}

  defp follow_manager(state, :requested_throttle_source, source)
       when source == state.requested_throttle_source,
       do: state

  defp follow_manager(state, :requested_throttle_source, source),
    do: %{state | requested_throttle_source: source, requested_throttle: @zero}

  defp follow_manager(state, :requested_steering_source, source)
       when source == state.requested_steering_source,
       do: state

  defp follow_manager(state, :requested_steering_source, source),
    do: %{state | requested_steering_source: source, requested_steering: @zero}

  defp follow_manager(state, _name, _value), do: state
end
