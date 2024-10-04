defmodule VmsCore.VwPolo.PowerSteeringPump do
  use GenServer
  alias Cantastic.{Emitter}
  alias VmsCore.Bus

  @loop_period 10
  @disabling_rotation_per_minute 0
  @enabling_rotation_per_minute 1500

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{selected_gear_source: selected_gear_source}) do
    Bus.subscribe("messages")
    :ok = Emitter.configure(:misc, "engine_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "rotations_per_minute" => 0
      },
      enable: true
    })
    :ok = Emitter.configure(:misc, "handbrake_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "handbrake_engaged" => false
      },
      enable: true
    })
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      selected_gear: "parking",
      selected_gear_source: selected_gear_source,
      enabled: false
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    case {state.enabled, state.selected_gear} do
      {true, :parking} ->
        set_rotation_per_minute(@disabling_rotation_per_minute)
        {:noreply, %{state | enabled: false}}
      {false, gear} when gear == :drive or gear == :reverse ->
        set_rotation_per_minute(@enabling_rotation_per_minute)
        {:noreply, %{state | enabled: true}}
      _ ->
        {:noreply, state}
    end
  end
  def handle_info(%Bus.Message{name: :selected_gear, value: selected_gear, source: source}, state) when source == state.selected_gear_source do
    {:noreply, %{state | selected_gear: selected_gear}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp set_rotation_per_minute(rotation_per_minute) do
    :ok = Emitter.update(:misc, "engine_status", fn (data) ->
      %{data | "rotations_per_minute" => rotation_per_minute}
    end)
  end
end
