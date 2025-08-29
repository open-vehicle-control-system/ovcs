defmodule InfotainmentCore.Vehicles.OBD2 do
  @moduledoc """
    Implements a basic OBD2 mapper reading RPM and speed
  """
  use GenServer
  require Logger
  alias Decimal, as: D
  alias Cantastic.{Signal, Receiver, Frame}

  @zero D.new(0)
  @loop_period 20

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), :ovcs, ["drivetrain_status"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      rotation_per_minute: @zero,
      speed: @zero,
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "drivetrain_status", signals: signals}}, state) do
    %{"speed" => %Signal{value: speed}} = signals
    %{"rotation_per_minute" => %Signal{value: rotation_per_minute}} = signals

    {:noreply, %{
      state |
        speed: D.new(speed),
        rotation_per_minute: D.new(rotation_per_minute)
      }
    }
  end

  def handle_call(:status, _from, state) do
    status = state |> Map.take([
      :speed,
      :rotation_per_minute,
    ])
    {:reply, {:ok, status}, state}
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end
end
