defmodule VmsApiWeb.RefreshIntervalTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias VmsApiWeb.{MetricsChannel, NetworkInterfacesChannel}

  for {channel, topic} <- [
        {MetricsChannel, "metrics"},
        {NetworkInterfacesChannel, "network-interfaces"}
      ] do
    describe topic do
      for interval <- [0, 1, 49, -1, 60_001, nil, "70", 70.0, %{}] do
        test "rejects interval #{inspect(interval)} before scheduling work" do
          assert {:error, %{reason: reason}} =
                   join(unquote(channel), unquote(topic), %{
                     "interval" => unquote(Macro.escape(interval))
                   })

          assert is_binary(reason)
          refute_received :push_network_interfaces
          refute_received :push_metrics
        end
      end

      test "rejects a missing interval" do
        assert {:error, %{reason: _reason}} = join(unquote(channel), unquote(topic), %{})
      end

      for interval <- [50, 70, 1000, 60_000] do
        test "accepts interval #{interval}" do
          assert {:ok, _socket} =
                   join(unquote(channel), unquote(topic), %{"interval" => unquote(interval)})
        end
      end
    end
  end

  defp join(channel, topic, payload) do
    case channel.join(topic, payload, %Phoenix.Socket{}) do
      {:ok, socket} = joined ->
        if timer = socket.assigns[:timer], do: :timer.cancel(timer)
        joined

      rejected ->
        rejected
    end
  end
end
