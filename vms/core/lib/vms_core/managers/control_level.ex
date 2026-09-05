defmodule VmsCore.Managers.ControlLevel do
  @moduledoc """
    Decide which control level should be selected based on the requested one and the other constraints

  ## Two orthogonal axes

  Authority and commander are separate questions, and the transmitter
  answers them on separate switches:

      requested_control_level   who has authority   :manual / :radio / :ros
      requested_ros_commander   which ROS node      :teleop / :autonomous

  `:ros` says the vehicle takes its commands from the ROS bridge. It
  does not say the vehicle is driving itself -- a human on a gamepad
  reaches the VMS through exactly the same topics and CAN frames as a
  planner does. That distinction is the second axis, and it is why the
  level is named `:ros` rather than `:autonomous`.

  Only the `:ros` level consults the commander. Every other level maps
  to a single source, so the second switch is inert in `:manual` and
  `:radio` -- which is what makes it safe to set up on a bench.

  ## Sources

  Each `requested_*_sources` map is keyed by level. The `:ros` entry is
  itself keyed by commander:

      requested_throttle_sources: %{
        manual: OVCS.ThrottlePedal,
        radio: OVCS.RadioControl.Throttle,
        ros: %{teleop: OVCS.ROSControl.Throttle, autonomous: OVCS.Ros2Control.Velocity}
      }

  A missing key resolves to `nil`, which means nothing commands that
  actuator. That is the safe direction: a vehicle with no planner wires
  `ros: %{teleop: ...}` and the autonomous position simply commands
  nothing rather than falling back to something that was not asked for.
  """
  use GenServer
  require Logger
  alias OvcsBus, as: Bus
  alias Decimal, as: D

  @loop_period 10
  @zero D.new(0)
  @default_ros_commander :teleop

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(
        %{
          requested_control_level_source: requested_control_level_source,
          requested_gear_sources: requested_gear_sources,
          requested_direction_sources: requested_direction_sources,
          requested_throttle_sources: requested_throttle_sources,
          requested_steering_sources: requested_steering_sources,
          manual_breaking_source: manual_breaking_source,
          radio_breaking_source: radio_breaking_source,
          default_control_level: default_control_level,
          ready_to_drive_source: ready_to_drive_source,
          speed_source: speed_source
        } = args
      ) do
    Enum.each(
      [
        requested_gear_sources: requested_gear_sources,
        requested_direction_sources: requested_direction_sources,
        requested_throttle_sources: requested_throttle_sources,
        requested_steering_sources: requested_steering_sources
      ],
      fn {key, sources} -> validate_sources!(key, sources) end
    )

    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    # Optional: a vehicle with no second switch never leaves `:teleop`,
    # so a planner it does not have can never take the wheel.
    requested_ros_commander_source = args[:requested_ros_commander_source]

    {:ok,
     %{
       loop_timer: timer,
       requested_gear_sources: requested_gear_sources,
       requested_direction_sources: requested_direction_sources,
       requested_throttle_sources: requested_throttle_sources,
       requested_steering_sources: requested_steering_sources,
       requested_control_level_source: requested_control_level_source,
       requested_ros_commander_source: requested_ros_commander_source,
       requested_ros_commander: @default_ros_commander,
       selected_ros_commander: @default_ros_commander,
       manual_breaking_source: manual_breaking_source,
       manual_breaking: false,
       radio_breaking_source: radio_breaking_source,
       radio_breaking: false,
       forced_control_level: nil,
       requested_control_level: nil,
       selected_control_level: default_control_level,
       # Logged-refusal bookkeeping, so an unhonourable request warns
       # once rather than at the loop frequency.
       refusal_logged: nil,
       requested_gear_source:
         source_for(requested_gear_sources, default_control_level, @default_ros_commander),
       requested_direction_source:
         source_for(requested_direction_sources, default_control_level, @default_ros_commander),
       requested_throttle_source:
         source_for(requested_throttle_sources, default_control_level, @default_ros_commander),
       requested_steering_source:
         source_for(requested_steering_sources, default_control_level, @default_ros_commander),
       ready_to_drive_source: ready_to_drive_source,
       ready_to_drive: false,
       speed_source: speed_source,
       speed: @zero
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    state =
      state
      |> select_control_level()
      |> select_ros_commander()
      |> select_sources()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(
        %Bus.Message{
          name: :requested_control_level,
          value: requested_control_level,
          source: source
        },
        state
      )
      when source == state.requested_control_level_source do
    {:noreply, %{state | requested_control_level: requested_control_level}}
  end

  def handle_info(
        %Bus.Message{
          name: :requested_ros_commander,
          value: requested_ros_commander,
          source: source
        },
        state
      )
      when source == state.requested_ros_commander_source do
    {:noreply, %{state | requested_ros_commander: requested_ros_commander}}
  end

  def handle_info(
        %Bus.Message{name: :manual_breaking, value: manual_breaking, source: source},
        state
      )
      when source == state.manual_breaking_source do
    {:noreply, %{state | manual_breaking: manual_breaking}}
  end

  def handle_info(
        %Bus.Message{name: :radio_breaking, value: radio_breaking, source: source},
        state
      )
      when source == state.radio_breaking_source do
    {:noreply, %{state | radio_breaking: radio_breaking}}
  end

  def handle_info(
        %Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: source},
        state
      )
      when source == state.ready_to_drive_source do
    {:noreply, %{state | ready_to_drive: ready_to_drive}}
  end

  def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state)
      when source == state.speed_source do
    {:noreply, %{state | speed: speed}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp select_control_level(state) when not is_nil(state.requested_control_level_source) do
    %{
      ready_to_drive: ready_to_drive,
      forced_control_level: forced_control_level,
      requested_control_level: requested_control_level,
      selected_control_level: selected_control_level,
      manual_breaking: manual_breaking,
      radio_breaking: radio_breaking,
      speed: speed
    } = state

    cond do
      selected_control_level != :manual && (manual_breaking || !ready_to_drive) ->
        %{state | selected_control_level: :manual, forced_control_level: :manual}

      selected_control_level == :ros && radio_breaking ->
        %{state | selected_control_level: :radio, forced_control_level: :radio}

      requested_control_level == :manual && selected_control_level != :manual ->
        %{state | selected_control_level: :manual}

      requested_control_level == :radio && selected_control_level != :radio &&
        is_nil(forced_control_level) && ready_to_drive && speed |> D.eq?(@zero) ->
        %{state | selected_control_level: :radio}

      requested_control_level == :ros && selected_control_level == :radio &&
        is_nil(forced_control_level) && speed |> D.eq?(@zero) ->
        %{state | selected_control_level: :ros}

      requested_control_level == selected_control_level &&
          requested_control_level == forced_control_level ->
        %{state | forced_control_level: nil}

      true ->
        log_refusal(state)
    end
  end

  defp select_control_level(state), do: state

  # Nothing matched, which is fine when the request is already
  # satisfied and a real problem otherwise. The switch left in `:ros`
  # while the vehicle sits in `:manual` is the case worth saying out
  # loud: `:ros` is only reachable *from* `:radio`, so the operator has
  # to step down through the middle position.
  defp log_refusal(state) do
    refusal = {state.requested_control_level, state.selected_control_level}

    cond do
      # Nothing has been requested yet: no frame has arrived, so there
      # is no refusal to report.
      is_nil(state.requested_control_level) ->
        state

      state.requested_control_level == state.selected_control_level ->
        %{state | refusal_logged: nil}

      state.refusal_logged == refusal ->
        state

      true ->
        {requested, selected} = refusal

        Logger.warning(
          "Control level #{inspect(requested)} requested but staying in " <>
            "#{inspect(selected)}: #{inspect(refusal_reason(state))}"
        )

        %{state | refusal_logged: refusal}
    end
  end

  defp refusal_reason(state) do
    cond do
      not is_nil(state.forced_control_level) ->
        {:forced, state.forced_control_level}

      not state.ready_to_drive ->
        :not_ready_to_drive

      not D.eq?(state.speed, @zero) ->
        {:moving, state.speed}

      state.requested_control_level == :ros && state.selected_control_level == :manual ->
        # `:ros` is only reachable from `:radio`, deliberately: it puts
        # the middle position between "nothing drives" and "ROS drives".
        :ros_only_reachable_from_radio

      true ->
        :unknown
    end
  end

  # Handing the vehicle to a planner is a mode change like any other,
  # so it waits for a standstill. Taking it back is unconditional and
  # immediate -- an operator reaching for the switch because the
  # planner is doing something wrong must not be made to stop first.
  defp select_ros_commander(state) when not is_nil(state.requested_ros_commander_source) do
    cond do
      state.requested_ros_commander == :teleop ->
        %{state | selected_ros_commander: :teleop}

      # Off the `:ros` level the commander is disarmed, so re-entering
      # it goes back through the standstill gate rather than resuming
      # a planner that was driving when authority was taken away.
      state.selected_control_level != :ros ->
        %{state | selected_ros_commander: :teleop}

      state.selected_ros_commander == :teleop && D.eq?(state.speed, @zero) ->
        %{state | selected_ros_commander: :autonomous}

      true ->
        state
    end
  end

  defp select_ros_commander(state), do: %{state | selected_ros_commander: @default_ros_commander}

  defp select_sources(state) when not is_nil(state.requested_control_level_source) do
    %{selected_control_level: level, selected_ros_commander: commander} = state

    %{
      state
      | requested_direction_source:
          source_for(state.requested_direction_sources, level, commander),
        requested_gear_source: source_for(state.requested_gear_sources, level, commander),
        requested_throttle_source: source_for(state.requested_throttle_sources, level, commander),
        requested_steering_source: source_for(state.requested_steering_sources, level, commander)
    }
  end

  defp select_sources(state), do: state

  # Only `:ros` is keyed by commander. Every other level names a single
  # source, so the second switch cannot affect it.
  defp source_for(sources, :ros, commander), do: sources[:ros][commander]
  defp source_for(sources, level, _commander), do: sources[level]

  # Checked once here rather than discovered on the first flip to
  # `:ros`, when a mis-shaped entry would crash the manager at the loop
  # frequency with a stack trace that never names the composer.
  defp validate_sources!(key, sources) when is_map(sources) do
    if Map.has_key?(sources, :autonomous) do
      raise ArgumentError,
            "#{inspect(key)} has an :autonomous level. The level is :ros, keyed by " <>
              "commander: ros: %{teleop: ..., autonomous: ...}"
    end

    case Map.get(sources, :ros) do
      ros when is_map(ros) or is_nil(ros) ->
        :ok

      other ->
        raise ArgumentError,
              "#{inspect(key)}[:ros] must be a map keyed by commander " <>
                "(%{teleop: ..., autonomous: ...}), got #{inspect(other)}"
    end
  end

  defp validate_sources!(key, sources) do
    raise ArgumentError, "#{inspect(key)} must be a map keyed by level, got #{inspect(sources)}"
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_control_level,
      value: state.requested_control_level,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :selected_control_level,
      value: state.selected_control_level,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :control_level_forced,
      value: !is_nil(state.forced_control_level),
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :selected_ros_commander,
      value: state.selected_ros_commander,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_direction_source,
      value: state.requested_direction_source,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_gear_source,
      value: state.requested_gear_source,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle_source,
      value: state.requested_throttle_source,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_steering_source,
      value: state.requested_steering_source,
      source: __MODULE__
    })

    state
  end
end
