defmodule VmsCore.Components.OBD2.Status do
  @moduledoc """
    OVCS Status module emitting metrics in the OVCS format
  """
  use GenServer
  alias VmsCore.Bus
  alias VmsCore.Components.OBD2.Status
  alias Cantastic.{Emitter}
  alias Decimal, as: D

  @zero D.new(0)
  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Emitter.configure(:ovcs, "obd2_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "speed" => @zero,
        "rotation_per_minute" => @zero,
      },
      enable: true
    })
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      speed: @zero,
      speed_requires_update: false,
      rotation_per_minute: @zero,
      rotation_per_minute_requires_update: false,
    }}
end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> handle_speed_status()
      |> handle_rotation_per_minute_status()
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :speed, value: speed}, state) do
    {:noreply, %{state |
      speed: speed,
      speed_requires_update: state.speed_requires_update || speed != state.speed
    }}
  end
  def handle_info(%Bus.Message{name: :rotation_per_minute, value: rpm}, state) do
    {:noreply, %{state |
      rotation_per_minute: rpm,
      rotation_per_minute_requires_update: state.rotation_per_minute_requires_update || rpm != state.rotation_per_minute
    }}
  end

  def handle_info(message, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp handle_speed_status(state) do
    case state.speed_requires_update do
      true ->
        :ok = Emitter.update(:ovcs, "obd2_status", fn (data) ->
          %{data |
            "speed" => state.speed,
          }
        end)
        %{state | speed_requires_update: false}
      false ->
        state
    end
  end

  defp handle_rotation_per_minute_status(state) do
    case state.rotation_per_minute_requires_update do
      true ->
        :ok = Emitter.update(:ovcs, "obd2_status", fn (data) ->
          %{data |
            "rotation_per_minute" => state.rotation_per_minute,
          }
        end)
        %{state | rotation_per_minute_requires_update: false}
      false ->
        state
    end
  end
end
