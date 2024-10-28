defmodule GadgetCompatibilityTest do
  use ExUnit.Case
  alias VintageNet.Interface.RawConfig
  alias VintageNet.Technology.Gadget

  #
  # These tests ensure that VintageNet.Technology.Gadget users get updated properly.
  # This is super-important to keep for a while so that pre-0.7.0 users are not broken.
  #
  test "gadget configurations are normalized to VintageNetDirect" do
    input = %{type: VintageNet.Technology.Gadget, random_field: 42}

    assert Gadget.normalize(input) == %{type: VintageNetDirect, vintage_net_direct: %{}}
  end

  test "normalization preserves hostname override" do
    input = %{type: VintageNet.Technology.Gadget, gadget: %{hostname: "my_host"}}

    assert Gadget.normalize(input) == %{
             type: VintageNetDirect,
             vintage_net_direct: %{hostname: "my_host"}
           }
  end

  test "create a gadget configuration" do
    input = %{
      type: VintageNet.Technology.Gadget,
      gadget: %{hostname: "test_hostname"}
    }

    output = Gadget.to_raw_config("usb0", input, Utils.default_opts())
    normalized_input = Gadget.normalize(input)

    expected = %RawConfig{
      ifname: "usb0",
      type: VintageNetDirect,
      source_config: normalized_input,
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
