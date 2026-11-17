defmodule SimulatorCore.World do
  @moduledoc """
  An external simulator that owns the vehicle's dynamics for
  `SimulatorCore.Hardware`, such as Gazebo through the ROS bridge.

  The loop hands the world the tick's efforts (`SimulatorCore.Efforts`):
  the world's own model moves the vehicle, with its slip, contacts and
  terrain, and reports its state (`SimulatorCore.WorldState`) in
  messages, which the simulated sensors measure. Exactly one model moves
  the vehicle; without a world, `SimulatorCore.FlatGround` is that
  model. Every callback runs in the loop's process, so `init/1`
  subscribes that process to what the world reports.
  """

  alias SimulatorCore.{Efforts, WorldState}

  @doc "Connects to the world: subscribes the calling process to what it reports."
  @callback init(opts :: keyword() | map()) :: state :: term()

  @doc """
  Hands the world the tick's efforts, applied for `dt_s`, with the
  world's state after it.
  """
  @callback actuate(Efforts.t(), dt_s :: float(), state :: term()) :: state :: term()

  @doc """
  The world's state from a message it sent, with the world's state
  after reading it; nil when the message is not the world's state.
  """
  @callback world_state(message :: term(), state :: term()) ::
              {WorldState.t(), state :: term()} | nil
end
