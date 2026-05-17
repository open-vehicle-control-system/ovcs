defmodule BNO085.Dummy do
  @moduledoc """
  Host-side stand-in for `BNO085.I2C`. Emits one of each
  `BNO085.Sample` kind on a 10 ms loop so consumers can be exercised
  end-to-end without an attached sensor. Same hardware-vocabulary
  contract as the real driver — no ROS / framework types here.
  """
  use GenServer
  require Logger

  alias BNO085.Sample

  # Static fixture values — picked to look obviously synthetic
  # downstream (small constant tilt, no rotation, ≈ 1 g on the z
  # axis after gravity).
  @samples [
    %Sample{kind: :acceleration, x: -0.84375, y: -0.15234375, z: 9.421875},
    %Sample{kind: :angular_velocity, x: 0.001953125, y: 0.001953125, z: 0.0},
    %Sample{kind: :rotation, x: 0.0, y: 0.0, z: 0.0, w: 0.99993896484375}
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
    Enum.each(@samples, fn sample ->
      Enum.each(state.listeners, fn listener ->
        GenServer.cast(listener, {:bno085_sample, sample})
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  def register_listener(listener) do
    GenServer.cast(__MODULE__, {:register_listener, listener})
  end

  def enable, do: :ok
end
