defmodule OvcsBusGateway.StartTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix)
    :ok
  end

  test "a gateway that cannot start is logged and ignored" do
    # As the supervisor starting it does.
    Process.flag(:trap_exit, true)
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)

    %{start: {module, function, args}} =
      OvcsBusGateway.child_spec(
        vehicle: OvcsMini,
        config: %OvcsBusGateway.Config{http: [port: port]}
      )

    log = capture_log(fn -> assert :ignore = apply(module, function, args) end)

    assert log =~ "Bus gateway not started"
    refute Process.whereis(OvcsBusGateway.Supervisor)
  end
end
