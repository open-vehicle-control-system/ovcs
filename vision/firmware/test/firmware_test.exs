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

  describe "the API on a board" do
    test "serves HTTPS on port 443 with a certificate kept on the application partition" do
      https = target_config(:arduino_ventuno_q)[:vision_api][VisionApiWeb.Endpoint][:https]

      assert https[:port] == 443
      assert Path.dirname(https[:certfile]) == "/data/vision_api"
      assert Path.dirname(https[:keyfile]) == "/data/vision_api"
    end

    test "redirects plain HTTP from port 80 and from port 4100, where it served plain HTTP before" do
      vision_api = target_config(:arduino_ventuno_q)[:vision_api]

      assert vision_api[VisionApiWeb.Endpoint][:http] == nil
      assert vision_api[:https_redirect_ports] == [80, 4100]
    end
  end

  defp erlinit_env(target) do
    erlinit = get_in(target_config(target), [:nerves, :erlinit]) || []
    Keyword.get_values(erlinit, :env)
  end

  defp target_config(target) do
    env = %{"VEHICLE" => "Ovcs1", "CI" => "true", "SECRET_KEY_BASE" => "test"}
    saved = Map.new(env, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(env)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        config = Config.Reader.read!("config/target.exs", env: :test, target: target)
        send(self(), {:config, config})
      end)

      assert_received {:config, config}
      config
    after
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
