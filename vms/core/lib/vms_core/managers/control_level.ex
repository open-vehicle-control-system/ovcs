defmodule VmsCore.Managers.ControlLevel do
  @moduledoc """
    Decide which control level should be selected based on the requested one and the other constraints
  """
  use GenServer
  alias VmsCore.Bus
  alias Decimal, as: D

  @loop_period 10
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
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
  }) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      requested_gear_sources: requested_gear_sources,
      requested_direction_sources: requested_direction_sources,
      requested_throttle_sources: requested_throttle_sources,
      requested_steering_sources: requested_steering_sources,
      requested_control_level_source: requested_control_level_source,
      manual_breaking_source: manual_breaking_source,
      manual_breaking: false,
      radio_breaking_source: radio_breaking_source,
      radio_breaking: false,
      forced_control_level: nil,
      requested_control_level: nil,
      selected_control_level: default_control_level,
      requested_gear_source: requested_gear_sources[default_control_level],
      requested_direction_source: requested_direction_sources[default_control_level],
      requested_throttle_source: requested_throttle_sources[default_control_level],
      requested_steering_source: requested_steering_sources[default_control_level],
      ready_to_drive_source: ready_to_drive_source,
      ready_to_drive: false,
      speed_source: speed_source,
      speed: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> select_control_level()
      |> select_sources()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :requested_control_level, value: requested_control_level, source: source}, state) when source == state.requested_control_level_source do
    {:noreply, %{state | requested_control_level: requested_control_level}}
  end
  def handle_info(%Bus.Message{name: :manual_breaking, value: manual_breaking, source: source}, state) when source == state.manual_breaking_source do
    {:noreply, %{state | manual_breaking: manual_breaking}}
  end
  def handle_info(%Bus.Message{name: :radio_breaking, value: radio_breaking, source: source}, state) when source == state.radio_breaking_source do
    {:noreply, %{state | radio_breaking: radio_breaking}}
  end
  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: source}, state) when source == state.ready_to_drive_source  do
    {:noreply, %{state | ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state) when source == state.speed_source do
    {:noreply, %{state | speed: speed}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
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
      selected_control_level == :autonomous && radio_breaking ->
        %{state | selected_control_level: :radio, forced_control_level: :radio}
      requested_control_level == :manual && selected_control_level != :manual ->
        %{state | selected_control_level: :manual}
      requested_control_level == :radio && selected_control_level != :radio && is_nil(forced_control_level) && ready_to_drive && speed |> D.eq?(@zero) ->
        %{state | selected_control_level: :radio}
      requested_control_level == :autonomous && selected_control_level == :radio && is_nil(forced_control_level) && speed |> D.eq?(@zero) ->
        %{state | selected_control_level: :autonomous}
      requested_control_level == selected_control_level && requested_control_level == forced_control_level ->
        %{state | forced_control_level: nil}
      true -> state
    end
  end
  defp select_control_level(state), do: state

  defp select_sources(state) when not is_nil(state.requested_control_level_source) do
    %{state |
      requested_direction_source: state.requested_direction_sources[state.selected_control_level],
      requested_gear_source: state.requested_gear_sources[state.selected_control_level],
      requested_throttle_source: state.requested_throttle_sources[state.selected_control_level],
      requested_steering_source: state.requested_steering_sources[state.selected_control_level],
    }
  end
  defp select_sources(state), do: state

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_control_level, value: state.requested_control_level, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :selected_control_level, value: state.selected_control_level, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :control_level_forced, value: !is_nil(state.forced_control_level), source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :requested_direction_source, value: state.requested_direction_source, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :requested_gear_source, value: state.requested_gear_source, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :requested_throttle_source, value: state.requested_throttle_source, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :requested_steering_source, value: state.requested_steering_source, source: __MODULE__})
    state
  end
end
