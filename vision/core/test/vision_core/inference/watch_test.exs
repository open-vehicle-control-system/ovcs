defmodule VisionCore.Inference.WatchTest do
  use ExUnit.Case, async: true

  alias VisionCore.Inference.Watch

  @moduletag :capture_log

  defp start_backend(name) do
    {:ok, pid} = Agent.start(fn -> nil end, name: name)
    pid
  end

  test "runs while the backend it watches runs, and exits when it goes down" do
    backend = start_backend(:watched_backend)

    watch =
      start_supervised!({Watch, server: :watched_backend, unit: :objects}, restart: :temporary)

    reference = Process.monitor(watch)

    Agent.stop(backend, :shutdown)

    assert_receive {:DOWN, ^reference, :process, ^watch, {:backend_down, :watched_backend}}
  end

  test "fails to start without the backend, saying which and for which unit" do
    assert {:error, message} = Watch.start_link(server: :no_such_backend, unit: :objects)
    assert message =~ "no_such_backend"
    assert message =~ "objects"
  end
end
