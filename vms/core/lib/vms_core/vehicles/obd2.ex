defmodule VmsCore.Vehicles.OBD2 do
  @moduledoc """
    Implements a basic OBD2 mapper reading RPM and speed
  """
  use GenServer
  require Logger
  alias VmsCore.{Bus}
  alias Decimal, as: D
  alias Cantastic.{Signal, Receiver, Emitter, Frame}

  @zero D.new(0)
  @loop_period 20

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :obd2, ["response"])
    :ok = Emitter.configure(:obd2, "command", %{
      parameters_builder_function: :default,
      initial_data: %{
        "data_length" => 0x02,
        "mode" => "current",
        "pid" => "rotation_per_minute"
      }
    })
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      rotation_per_minute: @zero,
      speed: @zero,
      current_pid: "rotation_per_minute"
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> emit_commands()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "response", signals: %{"pid" => %Signal{value: "rotation_per_minute"}} = signals}}, state) do
    %{"value" => %Signal{value: value}} = signals
    {:noreply, %{
      state |
        rotation_per_minute: value |> D.mult("0.25")
      }
    }
  end

  def handle_info({:handle_frame, %Frame{name: "response", signals: %{"pid" => %Signal{value: "speed"}} = signals}}, state) do
    %{"value" => %Signal{raw_value: raw_value}} = signals
    <<value::little-integer-size(8), _::binary>> = raw_value
    {:noreply, %{
      state |
        speed: D.new(value)
      }
    }
  end

  defp emit_commands(state) do
    :ok = Emitter.update(:obd2, "command", fn (data) ->
      %{data | "pid" => state.current_pid}
    end)
    Emitter.send_frame(:obd2, "command")

    next_pid = case state.current_pid do
      "speed" -> "rotation_per_minute"
      "rotation_per_minute" -> "speed"
    end
    %{state | current_pid: next_pid}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :rotation_per_minute, value: state.rotation_per_minute, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :speed, value: state.speed, source: __MODULE__})
    state
  end
end
