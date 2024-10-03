defmodule VmsCore.VwPolo.Dashboard do
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias VmsCore.Bus

  @max_rotation_per_minute 10000
  @loop_period 10

  @impl true
  def init(_) do
    :ok = Emitter.configure(:polo_drive, "engine_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "engine_rotations_per_minute" => 0
      }
    })
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    Bus.subscribe("messages")
    {:ok, %{
      loop_timer: timer,
      contact: :off,
      enabled: false
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    case {state.enabled, state.contact} do
      :on ->
        Emitter.enable(:polo_drive, "engine_status")
        %{state | enabled: true}
      {true, :off} ->
        Emitter.disable(:polo_drive, "engine_status")
        %{state | enabled: false}
      _ -> state
    end
      {:noreply, state}
  end

  def handle_info(%VmsCore.Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end

  @impl true
  def handle_info(%Bus.Message{name: :rotation_per_minute, value: rotation_per_minute}, state) do
    rotation_per_minute = case D.gt?(rotation_per_minute, @max_rotation_per_minute) do
      true  -> 0
      false -> rotation_per_minute
    end
    :ok = Emitter.update(:polo_drive, "engine_status", fn (data) ->
      %{data | "engine_rotations_per_minute" => rotation_per_minute}
    end)
    {:noreply, state}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end
end
