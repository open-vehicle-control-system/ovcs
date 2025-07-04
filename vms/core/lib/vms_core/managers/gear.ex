defmodule VmsCore.Managers.Gear do
  @moduledoc """
    Decide which gear should be selected based on the requested one and the other constraints
  """
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias VmsCore.Bus

  @gear_shift_throttle_limit D.new("0.05")
  @gear_shift_speed_limit D.new("1")
  @zero D.new(0)
  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    selected_control_level_source: selected_control_level_source,
    ready_to_drive_source: ready_to_drive_source,
    speed_source: speed_source,
    contact_source: contact_source})
  do
    Bus.subscribe("messages")
    :ok = Emitter.configure(:ovcs, "gear_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "selected_gear" => "parking"
      },
      enable: true
    })
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      selected_gear: :parking,
      requested_gear: :parking,
      requested_throttle: @zero,
      speed: @zero,
      ready_to_drive: false,
      loop_timer: timer,
      selected_control_level_source: selected_control_level_source,
      requested_throttle_source: nil,
      requested_gear_source: nil,
      requested_direction_source: nil,
      ready_to_drive_source: ready_to_drive_source,
      speed_source: speed_source,
      contact_source: contact_source,
      contact: nil
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> select_gear()
      |> emit_metrics()
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :requested_gear_source, value: requested_gear_source, source: source}, state) when source == state.selected_control_level_source do
    {:noreply, %{state | requested_gear_source: requested_gear_source}}
  end
  def handle_info(%Bus.Message{name: :requested_direction_source, value: requested_direction_source, source: source}, state) when source == state.selected_control_level_source do
    {:noreply, %{state | requested_direction_source: requested_direction_source}}
  end
  def handle_info(%Bus.Message{name: :requested_throttle_source, value: requested_throttle_source, source: source}, state) when source == state.selected_control_level_source do
    {:noreply, %{state | requested_throttle_source: requested_throttle_source}}
  end
  def handle_info(%Bus.Message{name: :requested_gear, value: requested_gear, source: source}, state) when source == state.requested_gear_source and is_nil(state.requested_direction_source) do
    {:noreply, %{state | requested_gear: requested_gear}}
  end
  def handle_info(%Bus.Message{name: :requested_direction, value: requested_direction, source: source}, state) when source == state.requested_direction_source and is_nil(state.requested_gear_source) do
    requested_gear = case requested_direction do
      :forward -> :drive
      :backward -> :reverse
    end
    {:noreply, %{state | requested_gear: requested_gear}}
  end
  def handle_info(%Bus.Message{name: :requested_throttle, value: requested_throttle, source: source}, state) when source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end
  def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state) when source == state.speed_source do
    {:noreply, %{state | speed: speed}}
  end
  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: source}, state) when source == state.ready_to_drive_source  do
    {:noreply, %{state | ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp select_gear(state) do
    %{
      contact: contact,
      requested_gear: requested_gear,
      selected_gear: selected_gear,
      ready_to_drive: ready_to_drive,
      speed: speed,
      requested_throttle: requested_throttle
    } = state

    speed_near_zero    = D.abs(speed) |> D.lt?(@gear_shift_speed_limit)
    throttle_near_zero = D.lt?(requested_throttle, @gear_shift_throttle_limit)

    cond do
      contact == :off && selected_gear != :parking ->
        apply_gear(state, :parking)
      !ready_to_drive && selected_gear in [:reverse, :drive] ->
        apply_gear(state, :neutral)
      selected_gear != :parking  && requested_gear == :parking && speed_near_zero && throttle_near_zero ->
        apply_gear(state, :parking)
      selected_gear != :neutral && requested_gear == :neutral && ready_to_drive ->
        apply_gear(state, :neutral)
      selected_gear != :reverse && requested_gear == :reverse &&  speed_near_zero && throttle_near_zero && ready_to_drive ->
        apply_gear(state, :reverse)
      selected_gear != :drive && requested_gear == :drive &&  speed_near_zero && throttle_near_zero && ready_to_drive ->
        apply_gear(state, :drive)
      true -> state
    end
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :selected_gear, value: state.selected_gear, source: __MODULE__})
    state
  end

  defp apply_gear(state, gear) do
    :ok = Emitter.update(:ovcs, "gear_status", fn (data) ->
      %{data | "selected_gear" => "#{gear}"}
    end)
    %{state | selected_gear: gear}
  end
end
