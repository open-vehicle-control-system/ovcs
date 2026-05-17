defmodule BNO085.Dummy do
  @moduledoc """
  Host-side stand-in for `BNO085.I2C`. Emits one of each
  `RosBridge.ImuSource.Reading` kind on a 10 ms loop so the IMU
  publish path runs end-to-end on `./ovcs run` without an attached
  sensor. Values are already in SI units — same contract as the
  real driver.
  """
  @behaviour RosBridge.ImuSource

  use GenServer
  require Logger

  alias Ros2.GeometryMsgs.Msg.Quaternion
  alias Ros2.GeometryMsgs.Msg.Vector3
  alias RosBridge.ImuSource.Reading

  # Static fixture values — picked to look obviously synthetic in
  # Foxglove (small constant tilt, no rotation, gravity-ish on z).
  @readings [
    %Reading{
      kind: :linear_acceleration,
      value: %Vector3{x: -0.84375, y: -0.15234375, z: 9.421875}
    },
    %Reading{
      kind: :angular_velocity,
      value: %Vector3{x: 0.001953125, y: 0.001953125, z: 0.0}
    },
    %Reading{
      kind: :orientation,
      value: %Quaternion{x: 0.0, y: 0.0, z: 0.0, w: 0.99993896484375}
    }
  ]

  def start_link(_opts) do
    Logger.debug("Starting #{__MODULE__}")
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok, _} = :timer.send_interval(10, :loop)
    {:ok, %{listeners: []}}
  end

  @impl true
  def handle_info(:loop, state) do
    Enum.each(@readings, fn reading ->
      Enum.each(state.listeners, fn listener ->
        GenServer.cast(listener, {:imu_reading, reading})
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  @impl RosBridge.ImuSource
  def register_listener(listener) do
    GenServer.cast(__MODULE__, {:register_listener, listener})
  end

  @impl RosBridge.ImuSource
  def enable, do: :ok
end
