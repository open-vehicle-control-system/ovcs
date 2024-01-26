defmodule Cantastic.Interface do
  use Agent
  alias Cantastic.Util

  def start_link(_) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def get_socket(name) do
    Agent.get(__MODULE__, fn (state) -> state[name] end)
  end

  def store_socket(name, socket) do
    Agent.update(__MODULE__, fn (state) -> Map.put(state, name, socket) end)
  end

  def send_frame(process_name, raw_frame) do
    socket = get_socket(process_name)
    Util.send_frame(socket, raw_frame)
  end
end
