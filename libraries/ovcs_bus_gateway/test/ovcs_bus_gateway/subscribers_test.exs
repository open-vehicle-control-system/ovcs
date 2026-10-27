defmodule OvcsBusGateway.SubscribersTest do
  use ExUnit.Case, async: false

  alias OvcsBusGateway.{Envelope, Subscribers}

  setup do
    start_supervised!(Subscribers)
    :ok
  end

  defp env(name), do: %Envelope{node: "vms", source: "A", name: name, value: 1, timestamp: 0}

  test "dispatch reaches every subscriber" do
    Subscribers.subscribe()
    test_pid = self()

    task =
      Task.async(fn ->
        Subscribers.subscribe()
        send(test_pid, :subscribed)

        receive do
          {:ovcs_bus_gateway, envelopes} -> envelopes
        end
      end)

    assert_receive :subscribed
    Subscribers.dispatch([env("speed")])

    assert_receive {:ovcs_bus_gateway, [%{name: "speed"}]}
    assert [%{name: "speed"}] = Task.await(task)
  end

  test "dispatch without subscribers is a no-op" do
    assert :ok = Subscribers.dispatch([env("speed")])
  end
end
