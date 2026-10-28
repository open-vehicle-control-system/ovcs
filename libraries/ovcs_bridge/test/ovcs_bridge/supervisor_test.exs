defmodule OvcsBridge.SupervisorTest do
  use ExUnit.Case, async: false

  defmodule FakeVehicle do
    @moduledoc false

    def bridge_firmwares do
      %{
        "plain" => %{
          target: :rpi4,
          bridges: [],
          children: [{Agent, fn -> :plain end}]
        },
        "by_build_target" => %{
          target: :rpi4,
          bridges: [],
          children: %{
            host: [{Phoenix.PubSub, name: OvcsBridge.SupervisorTest.PubSub}],
            target: [{Agent, fn -> :target end}]
          }
        }
      }
    end
  end

  setup do
    for {key, value} <- [vehicle: inspect(FakeVehicle), firmware_id: nil, build_target: :host] do
      previous = Application.get_env(:ovcs_bridge, key)
      Application.put_env(:ovcs_bridge, key, value)
      on_exit(fn -> Application.put_env(:ovcs_bridge, key, previous) end)
    end

    for name <- ~w(VEHICLE BRIDGE_FIRMWARE_ID) do
      previous = System.get_env(name)
      System.delete_env(name)
      on_exit(fn -> if previous, do: System.put_env(name, previous) end)
    end

    :ok
  end

  defp start_firmware(firmware_id, build_target) do
    Application.put_env(:ovcs_bridge, :firmware_id, firmware_id)
    Application.put_env(:ovcs_bridge, :build_target, build_target)
    pid = start_supervised!(OvcsBridge.Supervisor)
    Supervisor.which_children(pid)
  end

  test "starts the entry's children" do
    assert [{Agent, _pid, :worker, [Agent]}] = start_firmware("plain", :host)
  end

  test "picks the children of the build target" do
    assert [{Agent, _pid, :worker, [Agent]}] = start_firmware("by_build_target", :target)
  end

  test "starts the OTP application of a child's module first" do
    Application.stop(:phoenix_pubsub)

    assert [{Phoenix.PubSub.Supervisor, _pid, :supervisor, _modules}] =
             start_firmware("by_build_target", :host)

    assert Enum.any?(Application.started_applications(), &match?({:phoenix_pubsub, _, _}, &1))
  end
end
