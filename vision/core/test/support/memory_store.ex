defmodule VisionCore.Parameters.MemoryStore do
  @moduledoc """
  A `VisionCore.Parameters.Store` held in a named Agent, for registry tests.

  `load/0` returns no values when the Agent is not started, as the real
  store does when its database is unavailable.
  """
  use Agent

  def start_link(rows \\ %{}), do: Agent.start_link(fn -> rows end, name: __MODULE__)

  def load do
    if Process.whereis(__MODULE__), do: rows(), else: %{}
  end

  def write(changes) do
    Agent.update(__MODULE__, fn rows ->
      Enum.reduce(changes, rows, fn
        {id, :delete}, rows -> Map.delete(rows, id)
        {id, value}, rows -> Map.put(rows, id, value)
      end)
    end)
  end

  def rows, do: Agent.get(__MODULE__, & &1)
end
