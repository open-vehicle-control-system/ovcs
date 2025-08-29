defmodule VmsCore.Vehicles.OBD2 do
  @moduledoc """
    Implements a basic OBD2 mapper reading RPM and speed
  """
  use GenServer
  require Logger
  alias VmsCore.{Bus}
  alias Decimal, as: D
  alias Cantastic.{OBD2, Emitter}

  @zero D.new(0)
  @loop_period 20

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    :ok = Emitter.configure(:ovcs, "drivetrain_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "speed" => @zero,
        "rotation_per_minute" => @zero,
      },
      enable: true
    })
    OBD2.Request.subscribe(self(), :obd2, "current_speed_and_rotation_per_minute")
    OBD2.Request.enable(:obd2, "current_speed_and_rotation_per_minute")

    {:ok, %{
      loop_timer: timer,
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
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info({:handle_obd2_response, %OBD2.Response{request_name: "current_speed_and_rotation_per_minute", parameters: parameters}}, state) do
    %{
      "rotation_per_minute" => %OBD2.Parameter{value: rotation_per_minute},
      "speed"               => %OBD2.Parameter{value: speed}
    } = parameters
    {:noreply, %{
      state |
        rotation_per_minute: rotation_per_minute,
        rotation_per_minute_requires_update: state.rotation_per_minute_requires_update || rotation_per_minute != state.rotation_per_minute,
        speed: speed,
        speed_requires_update: state.speed_requires_update || speed != state.speed
      }
    }
  end

  defp handle_speed_status(state) do
    case state.speed_requires_update do
      true ->
        :ok = Emitter.update(:ovcs, "drivetrain_status", fn (data) ->
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
        :ok = Emitter.update(:ovcs, "drivetrain_status", fn (data) ->
          %{data |
            "rotation_per_minute" => state.rotation_per_minute,
          }
        end)
        %{state | rotation_per_minute_requires_update: false}
      false ->
        state
    end
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :rotation_per_minute, value: state.rotation_per_minute, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :speed, value: state.speed, source: __MODULE__})
    state
  end
end
