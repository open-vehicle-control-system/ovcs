defmodule VintageNetDirectTest do
  use ExUnit.Case
  alias VintageNet.Interface.RawConfig
  alias VintageNetDirect

  test "normalization simplifies configuration" do
    input = %{type: VintageNetDirect, random_field: 42}

    assert VintageNetDirect.normalize(input) == %{type: VintageNetDirect, vintage_net_direct: %{}}
  end

  test "normalization preserves hostname override" do
    input = %{type: VintageNetDirect, vintage_net_direct: %{hostname: "my_host"}}

    assert VintageNetDirect.normalize(input) == %{
             type: VintageNetDirect,
             vintage_net_direct: %{hostname: "my_host"}
           }
  end

  test "create a VintageNetDirect configuration" do
    input = %{
      type: VintageNetDirect,
      vintage_net_direct: %{hostname: "test_hostname"}
    }

    output = VintageNetDirect.to_raw_config("usb0", input, Utils.default_opts())

    expected = %RawConfig{
      ifname: "usb0",
      type: VintageNetDirect,
      source_config: input,
      required_ifnames: ["usb0"],
      child_specs: [
        {OneDHCPD.Server, ["usb0", [subnet: {172, 31, 246, 64}]]},
        {VintageNet.Connectivity.LANChecker, "usb0"}
      ],
      down_cmds: [
        {:fun, VintageNet.RouteManager, :clear_route, ["usb0"]},
        {:fun, VintageNet.NameResolver, :clear, ["usb0"]},
        {:run_ignore_errors, "ip", ["addr", "flush", "dev", "usb0", "label", "usb0"]},
        {:run, "ip", ["link", "set", "usb0", "down"]}
      ],
      files: [],
      up_cmd_millis: 5000,
      up_cmds: [
        {:run_ignore_errors, "ip", ["addr", "flush", "dev", "usb0", "label", "usb0"]},
        {:run, "ip", ["addr", "add", "172.31.246.65/30", "dev", "usb0", "label", "usb0"]},
        {:run, "ip", ["link", "set", "usb0", "up"]},
        {:fun, VintageNet.RouteManager, :clear_route, ["usb0"]},
        {:fun, VintageNet.NameResolver, :clear, ["usb0"]}
      ]
    }

    assert expected == output
  end
end
