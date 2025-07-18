defmodule VmsCore.Components.Traxxas.Motor do
  @moduledoc """
    Traxxas' motor feedback
  """
  use GenServer
  alias VmsCore.Bus

  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    controller: controller,
    rotation_per_minute_pin: rotation_per_minute_pin})
  do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      controller: controller,
      rotation_per_minute_pin: rotation_per_minute_pin,
      rotation_per_minute_pin_name: :received_analog_pin0_value, #TODO dynamic name
      raw_rotation_per_minute: 0,
      moving: false
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_values()
      |> emit_metrics()
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: name, value: raw_rotation_per_minute, source: source}, state) when source == state.controller and name == state.rotation_per_minute_pin_name do
    {:noreply, %{state | raw_rotation_per_minute: raw_rotation_per_minute}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp compute_values(state) do
    moving = case state.raw_rotation_per_minute do
      0 -> false
      _ -> true
    end
    %{state | moving: moving}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :raw_rotation_per_minute, value: state.raw_rotation_per_minute, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :moving, value: state.moving, source: __MODULE__})
    state
  end
end
