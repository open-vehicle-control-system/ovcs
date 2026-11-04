---
title: Radio control bridge
description: The bridge that lets a MAVLink-capable RC transmitter drive your vehicle, how its channels reach the VMS, how your vehicle configures it, and how to check it on the bench.
---

The radio control bridge, `RadioControlBridge`, lets a MAVLink-capable transmitter drive your vehicle: an ExpressLRS handset, an OpenTX or EdgeTX radio. It reads the receiver's channels from a UART and puts them on the `ovcs` CAN bus. It decides nothing: which channel steers, which one throttles and which one picks the control level is your VMS composer's choice.

> [!NOTE]
> The OVCS1 and OVCS Mini reference vehicles both run it, and appear here as worked examples. See [Framework and vehicles](../framework.md).

## How the channels reach the VMS

```text
transmitter ── ExpressLRS link ──> receiver ── UART, MAVLink v2 ──> RadioControlBridge.MavlinkForwarder
                                                                        │
                                       ovcs bus: 0x2A0 (channels 1-4), 0x2A1 (channels 5-8)
                                                                        │
                                                                        v
                     VMS: OVCS.RadioControl.Steering, .Throttle, .Direction, .RequestedControlLevel, .RequestedRosCommander
```

1. The receiver runs in MAVLink mode and sends MAVLink v2 `RC_CHANNELS_OVERRIDE` messages over a UART. [`express_lrs`](https://github.com/open-vehicle-control-system/express_lrs) decodes them.
2. `RadioControlBridge.MavlinkForwarder` copies channels 1 to 8 unchanged onto two `radio_control_channels` frames, `0x2A0` for channels 1 to 4 and `0x2A1` for 5 to 8, each channel a little-endian `uint16` in microseconds.
3. On the VMS, each `OVCS.RadioControl.*` component reads the channel your composer names and publishes its `requested_*` value. `VmsCore.Managers.ControlLevel` then decides whether the radio is in force. [Control levels](../vms/how_it_works.md#control-levels) covers the switches, each reference vehicle's channel layout and the safe fallbacks.

Every five seconds the forwarder logs a summary of the MAVLink traffic it received, which tells a silent link from a link that carries no RC messages.

The bridge also has an MSP OSD path for video goggles, `RadioControlBridge.MspOsdForwarder`, that sends nothing yet. [`msp_osd`](https://github.com/open-vehicle-control-system/msp_osd) provides the MSP DisplayPort transport for HDZero, Walksnail and DJI VTXs it will use.

## Configure it in your vehicle

Declare the bridge in an entry of `bridge_firmwares/0` (see [Bridge firmwares](./README.md#bridge-firmwares)), then implement the `RadioControlBridge` behaviour on your vehicle's top-level module. Its one callback returns a `%RadioControlBridge.Config{}` whose `components` list says which features run. From the OVCS Mini reference vehicle:

```elixir
@behaviour RadioControlBridge

@impl RadioControlBridge
def radio_control_bridge_config(:host),
  do: %RadioControlBridge.Config{components: []}

def radio_control_bridge_config(:target),
  do: %RadioControlBridge.Config{
    components: [{:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}]
  }
```

| Component | Options | Starts |
|---|---|---|
| `:mavlink_forwarder` | `:uart_port`, `:uart_baud_rate` (both required): the receiver's UART | `RadioControlBridge.MavlinkForwarder` |
| `:msp_osd_forwarder` | none | `RadioControlBridge.MspOsdForwarder` (sends nothing yet) |

A bare atom is shorthand for `{atom, []}`. An unknown component name raises at boot, so a typo fails loudly instead of silently dropping a feature.

The `:host` arm usually lists no components, since a workstation has no receiver UART. The UART settings live with the component that uses them: the bridge's `apply_runtime_config/2` copies the `:mavlink_forwarder` options into the `:express_lrs` application environment before `ExpressLrs.Application` starts its connector, which is why they are read once, at boot.

## Hardware

The receiver connects to a UART of the bridge's board. On the OVCS Mini, `ttySC0` at 460 800 baud is a UART of an SPI UART expander; on a board with a free hardware UART, name that one. The receiver's link must be in MAVLink mode, which on ExpressLRS forces Hybrid switch mode: [Channel layout](../vms/how_it_works.md#channel-layout) explains what that means for which channels carry three-position switches. [Hardware](../hardware.md) lists the boards and parts the reference vehicles use.

## Check it on the bench

With the bridge firmware running, the two frames appear on the `ovcs` bus as soon as the receiver is bound. From a workstation whose CAN adapter, `can0` here, sits on that bus:

```sh
candump can0,2A0:7FF,2A1:7FF
```

Without a transmitter, synthesise them with `cansend` on virtual CAN, as [Driving on the host bench](../vms/how_it_works.md#driving-on-the-host-bench) does for the OVCS Mini's channel layout.

## Where next

- [Control levels](../vms/how_it_works.md#control-levels): how the VMS turns the channels into commands.
- [Bridges](./README.md): the bridge firmware that hosts this bridge.
- [ROS bridge](./ros.md): the other command path, from a gamepad or a planner.
