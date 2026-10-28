defmodule BridgeFirmwareTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  test "a bus gateway that cannot start is logged and ignored" do
    {:ok, _apps} = Application.ensure_all_started(:ovcs_bus_gateway)
    # As the supervisor calling it does.
    Process.flag(:trap_exit, true)
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)

    opts = [vehicle: BridgeFirmwareTest, config: %OvcsBusGateway.Config{http: [port: port]}]

    log =
      capture_log(fn ->
        assert :ignore = BridgeFirmware.Application.start_bus_gateway(opts)
      end)

    assert log =~ "Bus gateway not started"
    refute Process.whereis(OvcsBusGateway.Supervisor)
  end
end
