# ros_bridge

Elixir bridge between the OVCS CAN bus and ROS 2, talking native
[Zenoh](https://zenoh.io) via [`zenohex`](https://hex.pm/packages/zenohex).
Hosted by `bridges/firmware`; vehicles opt in via `bridge_firmwares/0`.
The guide, [ROS bridge](../../docs/bridges/ros.md), explains its components, how a
vehicle configures it, the stereo tuning and the end-to-end check; this README keeps the
developer details.

The [vision unit](../../vision/core/README.md) runs stereo depth and detection as a role of its own, on a dedicated board, with a stereo stack of its own: this bridge matches with OpenCV's `StereoSGBM` through evision, the vision unit with Nx or its native `stereo_match` Port, without OpenCV.

## Layout

```
lib/
  ros_bridge.ex              # OvcsBridge behaviour + child list (host / target)
  zenoh_client.ex            # GenServer: Zenoh session + publish/subscribe API + rmw_zenoh liveliness
  ros_bridge/
    heartbeat.ex             # Periodic publisher (std_msgs/String on /ovcs_heartbeat) via ZenohClient.publish/4
    imu_publisher.ex         # OvcsDrivers.Imu consumer → sensor_msgs/Imu over Zenoh
    consumers/joy.ex         # ROS 2 /joy/<profile> → Cantastic emitter (steering, throttle, direction)
    consumers/joy/profile.ex # joy profile files: a controller's axes, pedals and gears
priv/joy/                    # the framework's joy profiles, one per controller
```

## ROS 2 messages and the rmw_zenoh wire format

The message codecs and the `rmw_zenoh` key expressions, payloads,
attachments and liveliness tokens come from
[`libraries/ros2_zenoh`](../../libraries/ros2_zenoh/README.md), which
also explains how to add a message type. `RosBridge.ZenohClient` holds
the Zenoh session and uses them to publish and subscribe.

## `RosBridge.ZenohClient`

A thin wrapper around a single `zenohex` session. Holds the TCP
peering with the configured Zenoh router (`tcp/<endpoint_ip>:7447`
in client mode), handles bounded-backoff reconnect (1 s → 30 s),
and exposes a small API for the rest of the bridge:

| Function | Purpose |
|---|---|
| `publish(topic, message_module, message, opts \\ [])` | Cast a CDR-encoded sample. First call for a topic lazily declares the underlying Zenoh publisher + its rmw_zenoh liveliness token; subsequent calls reuse them. Publisher GID + sequence number are stable across reconnects. |
| `subscribe(topic, message_module, pid \\ self(), opts \\ [])` | Register `pid` for `{:ros_message, {key_expr, parsed}}` deliveries. The pid is monitored — when it dies its registration is cleaned up and, if no consumers remain, the Zenoh subscriber is undeclared. |
| `unsubscribe(topic, pid \\ self())` | Symmetric. |

Init opts: `:endpoint_ip` (required), `:node_name` (default
`"ovcs_bridge"`), `:domain_id` (default `0`). Per-topic settings
(message module, interval, etc.) live on the *caller* — see
`RosBridge.Publishers.Heartbeat` for the smallest example.

Vehicles set the endpoint and the node name through `%RosBridge.Config{}`;
[Configure it in your vehicle](../../docs/bridges/ros.md#configure-it-in-your-vehicle)
explains both, including when two bridge firmwares need distinct node names.

## `RosBridge.Publishers.Heartbeat`

Periodic publisher built on top of `ZenohClient.publish/4`. The
default `:heartbeat` component ticks a `std_msgs/String` onto
`/ovcs_heartbeat` every 1 s so consumers can see the bridge is
alive; the same module works for any other periodic publish (just
pass a different `:message_module` + `:build` function in a child
spec).

## Adding a component

Each entry of `%RosBridge.Config{components: ...}` resolves to child specs through
`RosBridge.Components.start/2`, whose moduledoc is the reference for every component's
options. A new component is one more clause in `lib/ros_bridge/components.ex`.
