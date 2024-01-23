defmodule Cantastic.SocketStore do
  use Agent

  def start_link(initial_value) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def get(name) do
    Agent.get(__MODULE__, fn (state) -> state[name] end)
  end

  def set(name, socket) do
    Agent.update(__MODULE__, fn (state) -> Map.put(state, name, socket) end)
  end
end
