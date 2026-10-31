# ros_bridge

Elixir bridge between the OVCS CAN bus and ROS 2, talking native
[Zenoh](https://zenoh.io) via [`zenohex`](https://hex.pm/packages/zenohex).
Hosted by `bridges/firmware`; vehicles opt in via `bridge_firmwares/0`.

The [vision unit](../../vision/core/README.md) runs the same stereo depth and detection stack as a role of its own, on a dedicated board.

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

`:node_name` is what the bridge announces in its rmw_zenoh liveliness
tokens, i.e. the name `ros2 node list` and Foxglove show. Vehicles set
it through `RosBridge.Config.node_name`; leave it unset for a vehicle
that runs this bridge in a single bridge firmware. **A vehicle running
it in two bridge firmwares on one fabric must give each its own name**
— two bridges announcing `ovcs_bridge`
collide in the ROS graph, which `ros2 node list` reports as "nodes in
the graph that share an exact name" and Foxglove renders as a single
merged node. The OVCS Mini reference vehicle is a worked example of the
two-bridge case: `vehicles/ovcs_mini/lib/ovcs_mini.ex` runs
`ovcs_bridge_ros` and `ovcs_bridge_ros_vision`.

Endpoint comes from the vehicle's `RosBridge.Config.zenoh_endpoint_ip`
— set per-vehicle in `vehicles/<vehicle>/lib/<vehicle>.ex`. Override at
deployment time with `ZENOH_ENDPOINT_IP` (read at firmware build via
`bridges/firmware/config/target.exs`, baked into Application env,
then read at runtime by the vehicle's `ros_bridge_config(:target)`).

## `RosBridge.Publishers.Heartbeat`

Periodic publisher built on top of `ZenohClient.publish/4`. The
default `:heartbeat` component ticks a `std_msgs/String` onto
`/ovcs_heartbeat` every 1 s so consumers can see the bridge is
alive; the same module works for any other periodic publish (just
pass a different `:message_module` + `:build` function in a child
spec).

## Components — per-vehicle configuration

`RosBridge.children/0` is **not** hardcoded. Apart from
`ZenohClient` (always on), every other feature is a *component* the
vehicle opts into via the `:components` field of its
`%RosBridge.Config{}`. The bridge resolves each entry into one or
more child specs via `RosBridge.Components.start/2`.

Catalogue (extend by adding a clause to
`lib/ros_bridge/components.ex`):

| Component         | Opts                                                     | Child specs started                       |
|-------------------|----------------------------------------------------------|-------------------------------------------|
| `:heartbeat`      | `:interval_ms` (default `1_000`)                         | `RosBridge.Publishers.Heartbeat`                     |
| `:joy_interpreter`| `:profiles_dir`: the vehicle's own joystick profiles, added to the framework's in `priv/joy` (`RosBridge.Consumers.Joy.Profile`) | `RosBridge.Consumers.Joy`                |
| `:imu_publisher`  | `:driver` (required, an `OvcsDrivers.Imu` module); plus `:topic`, `:frame_id`, `:publish_interval_ms` forwarded | the driver, then `RosBridge.Publishers.Imu` |
| `:lidar_publisher` | `:driver` (required, an `OvcsDrivers.Lidar` module), `:driver_opts` (e.g. `serial_number: "..."`); plus `:topic` (`scan`), `:frame_id` (`laser`), `:bins` forwarded | the driver, then `RosBridge.Publishers.LaserScan` |
| `:vehicle_status_publisher` | `:topic_prefix` (`vehicle`) | `RosBridge.Publishers.VehicleStatus`: the VMS's status, gear and control level on `/vehicle/*`, from `0x1A0`, `0x600` and `0x60C` |
| `:range_publisher` | once per sensor: `:driver` (required, an `OvcsDrivers.Rangefinder` module), `:name` (required, unique), `:driver_opts`, `:topic` and `:frame_id` (required), `:radiation_type` | the driver instance, then `RosBridge.Publishers.Range` |
| `:hailo_detector` | `:hef_path` (required); plus `:score_threshold`, `:frame_id`, `:min_score`, `:max_detections`, `:depth_sample_fraction`, `:marker_lifetime_ms`, `:detect_every_n` | `RosBridge.Inference.Supervisor` (the `hailo_detect` Port owner, then `RosBridge.Publishers.Detections`) |

`:hailo_detector` requires `:stereo_camera` earlier in the same
vehicle's list — it registers on that unit's backend and consumes its
`Result`s. It publishes `<prefix>/detections/markers`
(`visualization_msgs/MarkerArray`, which is what Foxglove's 3D panel
renders) and `<prefix>/detections` (`vision_msgs/Detection3DArray`,
for nav2 and other consumers). See
`docs/ros2_perception.md`.

Vehicle example (`vehicles/<vehicle>/lib/<vehicle>.ex`):

```elixir
def ros_bridge_config(:host) do
  %RosBridge.Config{
    zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
    components: [
      :heartbeat,
      :joy_interpreter,
      {:imu_publisher, driver: OvcsDrivers.Imu.Dummy}
    ]
  }
end

def ros_bridge_config(:target) do
  %RosBridge.Config{
    zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
    # Optional; required only when more than one bridge firmware of the
    # vehicle runs the ROS bridge on the same Zenoh fabric.
    node_name: "ovcs_bridge_ros",
    components: [
      :heartbeat,
      :joy_interpreter,
      {:imu_publisher, driver: BNO085.I2C}
    ]
  }
end
```

A bare atom is shorthand for `{atom, []}`. An unknown component
name raises `FunctionClauseError` at supervisor boot — typos in the
list fail loudly rather than silently dropping a feature.

## Tuning the stereo cameras at runtime

The bridge's node serves ROS 2 parameters (`RosBridge.Parameters`), and
every `:stereo_camera` unit declares its settings there
(`RosBridge.StereoCamera.Parameters`), so they can be changed while
watching the images and the depth, from Foxglove's Parameters panel or
the `ros2 param` CLI (`<node>` is the bridge's `:node_name`):

```bash
ros2 param list /<node>
ros2 param describe /<node> stereo.left.lens_position
ros2 param set /<node> stereo.left.lens_position 1.2
ros2 param dump /<node>
```

| Parameters | Settings |
|---|---|
| `<prefix>.left.*`, `<prefix>.right.*` | each camera's runtime controls (`RosBridge.Camera.LibCamera.control_specs/0`): exposure mode, shutter time and gain (0 for automatic), focus, brightness, contrast, sharpness, noise reduction |
| `<prefix>.*` | the matching settings (`RosBridge.StereoCamera.OpenCV.option_specs/0`) |
| read-only | each camera's addressing, sync role, sensor mode and calibration file, and the resolution and frame rate |

Each parameter carries its type, range or accepted values and a
description; a value outside them is refused with the reason.

What the cameras actually apply goes to `/diagnostics`
(`RosBridge.StereoCamera.Live`): per camera the shutter time, gains,
focus, frame duration, colour temperature and sync state that libcamera
reports, and for the pair the time between the two cameras' frames,
with a warning above 1 ms. `<prefix>/live/sync_offset_ms` and each
camera's `<prefix>/live/<side>/exposure_time_us` and `analogue_gain`
(`std_msgs/Float64`) carry the same values for plotting.

Changes last until the stereo unit restarts: copy the values you keep
from `ros2 param dump` into the vehicle's configuration. The Foxglove
layout `compose/local/foxglove/ovcs_stereo_tuning.json` shows both
cameras, rectified so their rows align as the matcher sees them, and
the depth next to the stereo parameters as sliders, menus
and toggles (the `compose/local/foxglove/extensions/parameter-sliders`
panel, installed once in Foxglove), the diagnostics and
plots of the sync offset, exposure and gain.

## Host vs. target

`RosBridge.children/0` passes the active arm (`:host` or `:target`,
baked in at compile time from `Mix.target()`) to the vehicle's
`ros_bridge_config/1`. That's where the host/target distinction
lives: the vehicle returns whatever `:components` (and driver
modules) make sense for each environment — typically
`OvcsDrivers.Imu.Dummy` for `:host` so `./ovcs run` works without
an attached sensor, `BNO085.I2C` for `:target` to talk to the real
chip. Endpoint IP can also differ per arm (loopback router on
host, vehicle LAN IP on target).

## Verifying end-to-end

With `./ovcs run <vehicle>` going and the `compose/local/base.yml`
stack up:

```sh
cd compose/local && docker compose -f base.yml exec ros2 bash -lc '
  source /opt/ros/*/setup.bash
  ros2 topic list
  ros2 topic info -v /ovcs_heartbeat
  ros2 topic echo /ovcs_heartbeat std_msgs/msg/String
'
```

Or open Foxglove Studio against `ws://<docker-host>:8765` and
subscribe to `/ovcs_heartbeat` in a Raw Messages panel.
