defmodule RosBridge.Imu.BnoAdapter do
  @moduledoc """
  Bridges a `BNO085.*` driver to `RosBridge.ImuPublisher`. Subscribes
  to the driver, translates each `%BNO085.Sample{}` into a
  `%RosBridge.ImuSource.Reading{}` (wrapping the SI floats in
  `Ros2.GeometryMsgs.Msg.{Vector3, Quaternion}`), and fans it out to
  its own listeners.

  This is the only module in the tree that imports both `BNO085.*`
  and `Ros2.*` — keeping that coupling here lets the BNO driver stay
  pure-hardware (eventually liftable into a standalone library) and
  the publisher stay pure-ROS (knows only about `ImuSource`).
  """
  @behaviour RosBridge.ImuSource

  use GenServer

  alias BNO085.Sample
  alias Ros2.GeometryMsgs.Msg.Quaternion
  alias Ros2.GeometryMsgs.Msg.Vector3
  alias RosBridge.ImuSource.Reading

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    bno_module = Keyword.fetch!(opts, :bno_module)
    bno_module.register_listener(self())
    {:ok, %{bno_module: bno_module, listeners: []}}
  end

  @impl true
  def handle_cast({:bno085_sample, %Sample{} = sample}, state) do
    reading = to_reading(sample)

    if reading do
      Enum.each(state.listeners, fn listener ->
        GenServer.cast(listener, {:imu_reading, reading})
      end)
    end

    {:noreply, state}
  end

  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  @impl RosBridge.ImuSource
  def register_listener(listener) do
    GenServer.cast(__MODULE__, {:register_listener, listener})
  end

  @impl RosBridge.ImuSource
  def enable do
    GenServer.call(__MODULE__, :enable)
  end

  @impl true
  def handle_call(:enable, _from, state) do
    state.bno_module.enable()
    {:reply, :ok, state}
  end

  defp to_reading(%Sample{kind: :acceleration, x: x, y: y, z: z}) do
    %Reading{kind: :linear_acceleration, value: %Vector3{x: x, y: y, z: z}}
  end

  defp to_reading(%Sample{kind: :angular_velocity, x: x, y: y, z: z}) do
    %Reading{kind: :angular_velocity, value: %Vector3{x: x, y: y, z: z}}
  end

  defp to_reading(%Sample{kind: :rotation, x: x, y: y, z: z, w: w}) do
    %Reading{kind: :orientation, value: %Quaternion{x: x, y: y, z: z, w: w}}
  end
end
