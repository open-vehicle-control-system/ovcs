defmodule VisionCore.TestProcesses do
  @moduledoc """
  Registers a test's stand-in for a pipeline's process in
  `VisionCore.Processes`, which takes only a process registering itself.
  """

  @doc """
  Has `server`, a `VisionCore.Pipelines.server/2` name, reach `pid`: a
  process registered under it hands `pid` every message it gets, and
  exits with it.
  """
  @spec register(pid(), GenServer.name()) :: true
  def register(pid, {:via, Registry, {registry, key}}) do
    test = self()

    spawn(fn ->
      {:ok, _owner} = Registry.register(registry, key, nil)
      monitor = Process.monitor(pid)
      send(test, {:registered, key})
      forward(pid, monitor)
    end)

    receive do
      {:registered, ^key} -> true
    end
  end

  defp forward(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok

      message ->
        send(pid, message)
        forward(pid, monitor)
    end
  end
end
