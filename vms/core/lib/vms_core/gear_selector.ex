defmodule VmsCore.GearSelector do
  use GenServer
  alias VmsCore.Bus
  alias Decimal, as: D
  alias Cantastic.Emitter

  @gear_shift_throttle_limit D.new("0.05")
  @gear_shift_speed_limit D.new("1")
  @zero D.new(0)
  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    requested_gear_source: requested_gear_source,
    ready_to_drive_source: ready_to_drive_source,
    requested_throttle_source: requested_throttle_source,
    speed_source: speed_source})
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
      requested_throttle: @zero,
      speed: @zero,
      ready_to_drive: false,
      loop_timer: timer,
      requested_gear_source: requested_gear_source,
      ready_to_drive_source: ready_to_drive_source,
      speed_source: speed_source,
      requested_throttle_source: requested_throttle_source
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    Bus.broadcast("messages", %Bus.Message{name: :selected_gear, value: state.selected_gear, source: __MODULE__})
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :requested_gear, value: requested_gear, source: source}, state) when source == state.requested_gear_source do
    case validate_requested_gear(state, requested_gear) do
      {:change, selected_gear} ->
        :ok = Cantastic.Emitter.update(:ovcs, "gear_status", fn (data) ->
          %{data | "selected_gear" => "#{selected_gear}"}
        end)
        {:noreply,%{state | selected_gear: selected_gear}}
      :no_change ->
        {:noreply, state}
    end
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
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp validate_requested_gear(state, requested_gear) do
    throttle_near_zero = D.lt?(state.requested_throttle, @gear_shift_throttle_limit)
    speed_near_zero    = D.abs(state.speed) |> D.lt?(@gear_shift_speed_limit)
    ready_to_drive     = state.ready_to_drive
    selected_gear      = state.selected_gear
    case {selected_gear, requested_gear, throttle_near_zero && speed_near_zero, ready_to_drive} do
      {:parking, :parking, _, _} -> :no_change
      {:reverse, :reverse, _, _} -> :no_change
      {:neutral, :neutral, _, _} -> :no_change
      {:drive, :drive, _, _}     -> :no_change
      {_, :parking, true, _}     -> {:change, :parking}
      {_, :reverse, true, true}  -> {:change, :reverse}
      {_, :drive, true, true}    -> {:change, :drive}
      {_, :neutral, _, _}        -> {:change, :neutral}
      _                          -> :no_change
    end
  end
end
