defmodule VisionFirmwareTest do
  use ExUnit.Case, async: false

  test "declares the dashboard dev add-on" do
    assert [%{name: "dashboard", dir: "../dashboard"}] = VisionFirmware.dev_addons()
  end

  test "records the commit it is built from and its target, for OvcsVehicle.FirmwareInfo" do
    firmware = Application.fetch_env!(:ovcs_vehicle, :firmware)

    assert firmware[:target] == "host"
    assert firmware[:revision] =~ ~r/^(v\d\S*|[0-9a-f]{7,}(-dirty)?)$/
  end

  describe "erlinit" do
    test "starts the VENTUNO Q's VM with 512 MiB Vulkan slabs, and no other target's" do
      assert erlinit_env(:arduino_ventuno_q) == ["IREE_HAL_VULKAN_SLAB_SIZE=536870912"]
      assert erlinit_env(:okdo_c100) == []
      assert erlinit_env(:rpi5) == []
    end
  end

  defp erlinit_env(target) do
    env = %{"VEHICLE" => "Ovcs1", "CI" => "true", "SECRET_KEY_BASE" => "test"}
    saved = Map.new(env, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(env)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        config = Config.Reader.read!("config/target.exs", env: :test, target: target)
        send(self(), {:erlinit, get_in(config, [:nerves, :erlinit]) || []})
      end)

      assert_received {:erlinit, erlinit}
      Keyword.get_values(erlinit, :env)
    after
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
