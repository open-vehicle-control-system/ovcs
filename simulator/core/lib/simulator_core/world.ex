defmodule SimulatorCore.World do
  @moduledoc """
  What moves the simulated vehicle for `SimulatorCore.Hardware`: an
  external simulator, such as Gazebo through the ROS bridge.

  The loop hands the world the vehicle's motion every tick, and learns
  from the world's messages how far the wheels turned, as the vehicle's
  motor and shaft sensors measure them. Every callback runs in the
  loop's process, so `init/1` subscribes that process to what the world
  reports.
  """

  alias SimulatorCore.Vehicle

  @doc "Connects to the world: subscribes the calling process to what it reports."
  @callback init(opts :: keyword() | map()) :: state :: term()

  @doc """
  How far the wheels have turned, in turns, cumulative, from a message
  the world sent; nil when the message does not say.
  """
  @callback wheel_turns(message :: term(), state :: term()) :: float() | nil

  @doc "Asks the world to move the vehicle as `vehicle` commands."
  @callback drive(Vehicle.t(), state :: term()) :: :ok
end
