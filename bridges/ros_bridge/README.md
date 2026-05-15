# ros_bridge

Elixir bridge between the OVCS CAN bus and ROS 2, talking native
[Zenoh](https://zenoh.io) via [`zenohex`](https://hex.pm/packages/zenohex).
Hosted by `bridges/firmware`; vehicles opt in via `bridge_firmwares/0`.

## Layout

```
lib/
  ros_bridge.ex              # OvcsBridge behaviour + child list (host / target)
  zenoh_client.ex            # GenServer: native Zenoh publisher + rmw_zenoh liveliness
  imu_publisher.ex           # BNO085 → CAN
  joy_interpreter.ex         # MQTT-plugin-era subscriber (currently disabled)
  zenoh_mqtt_ros2/
    dispatcher.ex            # MQTT-plugin path (currently disabled — kept for fallback)
    ros2/                    # ROS 2 message codecs (CDR encode + parse)
      common.ex              # Shared encoder/parser primitives (encode_string, …)
      rmw_zenoh.ex           # rmw_zenoh wire-format helpers (keyexpr, payload, attachment, liveliness)
      std_msgs/msg/string.ex # std_msgs/String + DDS type name + RIHS01 type hash
      sensor_msgs/, geometry_msgs/, builtin_interfaces/, std_msgs/msg/header.ex
```

## Native rmw_zenoh wire format

Reaching ROS 2 nodes (Foxglove, `ros2 topic echo`, rclpy) over plain
Zenoh requires three things plain `Zenohex.Publisher.put/3` does not
give you. `Ros2.RmwZenoh` builds them:

1. **Data keyexpr** — `<domain>/<topic>/<dds_type>/<type_hash>`.
   Example: `0/ovcs_heartbeat/std_msgs::msg::dds_::String_/RIHS01_df66…`.
   The DDS type name and RIHS01 hash come from each message module
   (`dds_type/0` + `type_hash/0`); the hash is per-distro and must
   be refreshed if the ROS distro changes — verify against a live
   node with `ros2 topic info -v <topic>` (the "Topic type hash" line).
2. **Payload** — CDR little-endian, prefixed with the encapsulation
   header `00 01 00 00`. Each message module exposes `encode/1`
   producing the CDR body; `Ros2.RmwZenoh.encode_payload/1` prepends
   the header.
3. **Publisher attachment** — 33 bytes carrying sequence number
   (i64 LE), source timestamp ns (i64 LE), GID length byte (= 16),
   and a 16-byte GID. Subscribers drop samples without a well-formed
   attachment. `Ros2.RmwZenoh.attachment/3` builds it; the GID is
   generated once per `ZenohClient` process and reused across
   reconnects so subscribers see a stable publisher identity.

In addition, the publisher must declare an rmw_zenoh
**liveliness token** of kind `MP` so graph introspection
(`ros2 topic list`, Foxglove's topic panel) can see the topic at all
— without it the data still flows on the right keyexpr but no node
knows the publisher exists. Format:

```
@ros2_lv/<domain>/<zid>/<nid>/<eid>/MP/<enclave>/<ns>/<node>/<topic>/<type>/<hash>/<qos>
```

Where `/` in enclave / namespace / topic is mangled to `%`, `<zid>`
is the Zenoh session ZID (from `Zenohex.Session.info/1`), `nid` and
`eid` are session-local counters (we use `0/0`), and `<qos>` is the
default reliable-volatile profile encoded as `::,:,:,:,,`. Built by
`Ros2.RmwZenoh.liveliness_key/5` and registered through
`Zenohex.Liveliness.declare_token/2`. The returned token reference
must stay in `ZenohClient`'s state — if it's GC'd, the token is
undeclared and the topic disappears from `ros2 topic list`.

## `RosBridge.ZenohClient`

Connects to the configured Zenoh router (`tcp/<endpoint_ip>:7447` in
client mode), declares one publisher + matching liveliness token, and
publishes a heartbeat `std_msgs/String` every 5 s. Bounded-backoff
reconnect (1 s → 30 s).

Default opts (overridable at `child_spec` time):

| Option         | Default                       |
|----------------|-------------------------------|
| `:topic`       | `"ovcs_heartbeat"`            |
| `:msg_module`  | `Ros2.StdMsgs.Msg.String`     |
| `:domain_id`   | `0`                           |
| `:node_name`   | `"ovcs_bridge"`               |
| `:interval_ms` | `5_000`                       |

Endpoint comes from the vehicle's `RosBridge.Config.zenoh_endpoint_ip`
— set per-vehicle in `vehicles/<v>/lib/<v>.ex`. Override at
deployment time with `ZENOH_ENDPOINT_IP` (read at firmware build via
`bridges/firmware/config/target.exs`, baked into Application env, then
read at runtime by the vehicle's `ros_bridge_config(:target)`).

## Adding a new ROS message type

1. Drop the codec under `lib/zenoh_mqtt_ros2/ros2/<pkg>/msg/<name>.ex`.
2. Add three things alongside any existing `parse/1`:
   - `def dds_type, do: "<pkg>::msg::dds_::<Name>_"`
   - `def type_hash, do: "RIHS01_<64-hex>"` — copy from
     `ros2 topic info -v` of any live publisher of this type.
   - `def encode(%__MODULE__{...})` returning the CDR-encoded body
     (no encapsulation header — that's added by
     `Ros2.RmwZenoh.encode_payload/1`).
3. Use it: `RmwZenoh.key_expr/3` and `RmwZenoh.encode_payload/1` work
   uniformly across types.

The hand-rolled CDR encoders/parsers in `Ros2.Common` are growing
ad-hoc; consolidate when you need the third or fourth message type.

## Host vs. target

`Mix.target() == :host` runs only `RosBridge.ZenohClient` (no I2C-backed
IMU, no MQTT dispatcher) so `./ovcs run` can drive the ROS publisher
path against a local `zenohd` (see `ros2/docker-compose.yml`). On
target the full stack runs.

## Verifying end-to-end

With `./ovcs run <vehicle>` going and the `ros2/docker-compose.yml`
stack up:

```sh
cd ros2 && docker compose exec ros2 bash -lc '
  source /opt/ros/jazzy/setup.bash
  ros2 topic list
  ros2 topic info -v /ovcs_heartbeat
  ros2 topic echo /ovcs_heartbeat std_msgs/msg/String
'
```

Or open Foxglove Studio against `ws://<docker-host>:8765` and
subscribe to `/ovcs_heartbeat` in a Raw Messages panel.
