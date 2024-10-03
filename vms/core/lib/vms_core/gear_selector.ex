defmodule VmsCore.GearSelector do
  use GenServer
  alias VmsCore.PubSub
  alias Decimal, as: D
  alias Cantastic.Emitter

  @gear_shift_throttle_limit D.new("0.05")
  @gear_shift_speed_limit D.new("1")
  @zero D.new(0)

  @impl true
  def init(_) do
    PubSub.subscribe("metrics")
    PubSub.subscribe("commands")
    :ok = Emitter.configure(:ovcs, "gear_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "selected_gear" => "parking"
      },
      enable: true
    })

    {:ok, %{
      selected_gear: :parking,
      requested_throttle: @zero,
      speeed: @zero,
      ready_to_drive: false
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(%PubSub.MetricMessage{name: :requested_gear, value: requested_gear}, state) do
    state = case validate_requested_gear(state.selected_gear, requested_gear) do
      :no_change -> state
      {:change, selected_gear} ->
        :ok = Cantastic.Emitter.update(:ovcs, "gear_status", fn (data) ->
          %{data | "selected_gear" => "#{selected_gear}"}
        end)
        PubSub.broadcast("commands", %PubSub.CommandMessage{name: :select_gear, value: selected_gear, previous_value: state.selected_gear, source: __MODULE__})
        %{state | selected_gear: selected_gear}
    end
    {:noreply,state}
  end

  @impl true
  def handle_info(%PubSub.MetricMessage{name: :requested_throttle, value: requested_throttle}, state) do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end
  def handle_info(%PubSub.MetricMessage{name: :speed, value: speed}, state) do
    {:noreply, %{state | speed: speed}}
  end
  def handle_info(%PubSub.CommandMessage{name: :change_ready_to_drive_status, value: ready_to_drive}, state) do
    {:noreply, %{state | ready_to_drive: ready_to_drive}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def current() do
    GenServer.call(__MODULE__, :current)
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
