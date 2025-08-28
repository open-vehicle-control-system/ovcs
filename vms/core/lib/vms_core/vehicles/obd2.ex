defmodule VmsCore.Vehicles.OBD2 do
  @moduledoc """
    Implements a basic OBD2 mapper reading RPM and speed
  """
  use GenServer
  require Logger
  alias VmsCore.{Bus}
  alias Decimal, as: D
  alias Cantastic.OBD2

  @zero D.new(0)
  @loop_period 20

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    OBD2.Request.subscribe(self(), :obd2, "current_speed_and_rotation_per_minute")
    OBD2.Request.enable(:obd2, "current_speed_and_rotation_per_minute")

    {:ok, %{
      loop_timer: timer,
      rotation_per_minute: @zero,
      speed: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      #|> request()
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
        speed: speed
      }
    }
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :rotation_per_minute, value: state.rotation_per_minute, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :speed, value: state.speed, source: __MODULE__})
    state
  end
end
