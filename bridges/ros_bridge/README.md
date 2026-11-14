# ros_bridge

Elixir bridge between the OVCS CAN bus and ROS 2, talking native
[Zenoh](https://zenoh.io) via [`zenohex`](https://hex.pm/packages/zenohex).
Hosted by `bridges/firmware`; vehicles opt in via `bridge_firmwares/0`.
The guide, [ROS bridge](../../docs/bridges/ros.md), explains its components, how a
vehicle configures it and the end-to-end check; this README keeps the developer details.

Stereo depth and detection are the [vision unit](../../vision/core/README.md)'s, a role of its own.

## Layout

```
lib/
  ros_bridge.ex              # OvcsBridge behaviour + child list (host / target)
  ros_bridge/
    heartbeat.ex             # Periodic publisher (std_msgs/String on /<node_name>/heartbeat) via Ros2Zenoh.Client.publish/4
    imu_publisher.ex         # OvcsDrivers.Imu consumer → sensor_msgs/Imu over Zenoh
    consumers/joy.ex         # ROS 2 /joy/<profile> → Cantastic emitter (steering, throttle, direction)
    consumers/joy/profile.ex # joy profile files: a controller's axes, pedals and gears
priv/joy/                    # the framework's joy profiles, one per controller
```

## ROS 2 messages and the rmw_zenoh wire format

The message codecs and the `rmw_zenoh` key expressions, payloads,
attachments and liveliness tokens come from
[`libraries/ros2_zenoh`](../../libraries/ros2_zenoh/README.md), which
also explains how to add a message type. Its `Ros2Zenoh.Client` holds
the Zenoh session the bridge publishes and subscribes through, started
first in the bridge's `rest_for_one` subtree. Per-topic settings
(message module, interval, etc.) live on the *caller* — see
`RosBridge.Publishers.Heartbeat` for the smallest example.

Vehicles set the endpoint and the node name (default `"ovcs_bridge"`)
through `%RosBridge.Config{}`;
[Configure it in your vehicle](../../docs/bridges/ros.md#configure-it-in-your-vehicle)
explains both, including when two bridge firmwares need distinct node names.

## `RosBridge.Publishers.Heartbeat`

Periodic publisher built on top of `Ros2Zenoh.Client.publish/4`. The
default `:heartbeat` component ticks a `std_msgs/String` onto
`/<node_name>/heartbeat` every 1 s so consumers can see the bridge is
alive; the same module works for any other periodic publish (just
pass a different `:message_module` + `:build` function in a child
spec).

## Adding a component

Each entry of `%RosBridge.Config{components: ...}` resolves to child specs through
`RosBridge.Components.start/2`, whose moduledoc is the reference for every component's
options. A new component is one more clause in `lib/ros_bridge/components.ex`.
