![vintage net logo](assets/logo.png)

[![Hex version](https://img.shields.io/hexpm/v/vintage_net_direct.svg "Hex version")](https://hex.pm/packages/vintage_net_direct)
[![API docs](https://img.shields.io/hexpm/v/vintage_net_direct.svg?label=hexdocs "API docs")](https://hexdocs.pm/vintage_net_direct/VintageNetDirect.html)
[![CircleCI](https://circleci.com/gh/nerves-networking/vintage_net_direct.svg?style=svg)](https://circleci.com/gh/nerves-networking/vintage_net_direct)
[![Coverage Status](https://coveralls.io/repos/github/nerves-networking/vintage_net_direct/badge.svg?branch=master)](https://coveralls.io/github/nerves-networking/vintage_net_direct?branch=master)

`VintageNetDirect` makes it easy to connect a device to a computer over a
directly connected Ethernet cable. This is a common USB setup where your
computer is connected via USB to a Nerves device.

Assuming that you have a USB gadget-capable device like a Raspberry Pi Zero, 3
A+ or Beaglebone, all that you need to do is add `:vintage_net_direct` to your
`mix` dependencies like this:

```elixir
def deps do
  [
    {:vintage_net_direct, "~> 0.7.0", targets: @all_targets}
  ]
end
```

And then add the following to your `:vintage_net` configuration:

```elixir
  config :vintage_net, [
    config: [
      {"usb0", %{type: VintageNetDirect}},
    ]
  ]
```

