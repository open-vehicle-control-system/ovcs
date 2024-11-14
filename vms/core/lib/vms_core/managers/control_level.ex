defmodule VmsCore.Managers.ControlLevel do
  @moduledoc """
    Decide which control level should be selected based on the requested one and the other constraints
  """
  use GenServer
  alias VmsCore.Bus

  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    requested_control_level_source: requested_control_level_source,
    manual_driver_brake_apply_source: manual_driver_brake_apply_source,
    default_control_level: default_control_level})
  do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      requested_control_level_source: requested_control_level_source,
      manual_driver_brake_apply_source: manual_driver_brake_apply_source,
      manual_driver_brake_apply: false,
      forced_to_manual: false,
      requested_control_level: nil,
      selected_control_level: default_control_level,
      loop_timer: timer
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> select_control_level()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :requested_control_level, value: requested_control_level, source: source}, state) when source == state.requested_control_level_source do
    {:noreply, %{state | requested_control_level: requested_control_level}}
  end
  def handle_info(%Bus.Message{name: :driver_brake_apply, value: driver_brake_apply, source: source}, state) when source == state.manual_driver_brake_apply_source do
    {:noreply, %{state | manual_driver_brake_apply: driver_brake_apply}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp select_control_level(state) when not is_nil(state.requested_control_level_source) do
    cond do
      state.requested_control_level == :radio && state.manual_driver_brake_apply == true ->
        %{state | selected_control_level: :manual, forced_to_manual: true}
      state.requested_control_level == :radio && state.selected_control_level == :manual && !state.forced_to_manual ->
        %{state | selected_control_level: :radio}
      state.requested_control_level == :manual && state.selected_control_level == :radio ->
        %{state |forced_to_manual: false, selected_control_level: :manual}
      true -> state
    end
  end
  defp select_control_level(state), do: state

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :selected_control_level, value: state.selected_control_level, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :requested_control_level, value: state.requested_control_level, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :forced_to_manual, value: state.forced_to_manual, source: __MODULE__})
    state
  end

end
