# ros_bridge

Elixir bridge between the OVCS CAN bus and ROS 2, talking native
[Zenoh](https://zenoh.io) via [`zenohex`](https://hex.pm/packages/zenohex).
Hosted by `bridges/firmware`; vehicles opt in via `bridge_firmwares/0`.

## Layout

```
lib/
  ros_bridge.ex              # OvcsBridge behaviour + child list (host / target)
  zenoh_client.ex            # GenServer: Zenoh session + publish/subscribe API + rmw_zenoh liveliness
  ros_bridge/
    heartbeat.ex             # Periodic publisher (std_msgs/String on /ovcs_heartbeat) via ZenohClient.publish/4
    imu_publisher.ex         # OvcsDrivers.Imu consumer → sensor_msgs/Imu over Zenoh
    joy_interpreter.ex       # ROS 2 /joy → Cantastic emitter (steering, throttle)
  ros2/                      # ROS 2 message codecs (CDR encode + parse)
    common.ex                # Shared encoder/parser primitives (encode_string, …)
    rmw_zenoh.ex             # rmw_zenoh wire-format helpers (key_expr, payload, attachment, liveliness)
    std_msgs/msg/string.ex   # std_msgs/String + DDS type name + RIHS01 type hash
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
`RosBridge.Heartbeat` for the smallest example.

Endpoint comes from the vehicle's `RosBridge.Config.zenoh_endpoint_ip`
— set per-vehicle in `vehicles/<v>/lib/<v>.ex`. Override at
deployment time with `ZENOH_ENDPOINT_IP` (read at firmware build via
`bridges/firmware/config/target.exs`, baked into Application env,
then read at runtime by the vehicle's `ros_bridge_config(:target)`).

## `RosBridge.Heartbeat`

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
| `:heartbeat`      | `:interval_ms` (default `1_000`)                         | `RosBridge.Heartbeat`                     |
| `:joy_interpreter`| —                                                        | `RosBridge.JoyInterpreter`                |
| `:imu_publisher`  | `:driver` (required, an `OvcsDrivers.Imu` module); plus `:topic`, `:frame_id`, `:publish_interval_ms` forwarded | the driver, then `RosBridge.ImuPublisher` |

Vehicle example (`vehicles/<v>/lib/<v>.ex`):

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

## Adding a new ROS message type

1. Drop the codec under `lib/ros2/<pkg>/msg/<name>.ex`.
2. For **publishing** add three things alongside any existing
   `parse/1`:
   - `def dds_type, do: "<pkg>::msg::dds_::<Name>_"`
   - `def type_hash, do: "RIHS01_<64-hex>"` — copy from
     `ros2 topic info -v` of any live publisher of this type.
   - `def encode(%__MODULE__{...})` returning the CDR-encoded body
     (no encapsulation header — that's added by
     `Ros2.RmwZenoh.encode_payload/1`).
3. For **subscribing** only `parse/1` is needed — the rmw_zenoh
   keyexpr is matched on the `<domain>/<topic>/**` wildcard, so the
   message's DDS type name and hash don't have to be hard-coded.
4. Use it: `RmwZenoh.key_expr/3` and `RmwZenoh.encode_payload/1` work
   uniformly across types for the publisher side;
   `RosBridge.ZenohClient.subscribe/2` covers the subscriber side.

The hand-rolled CDR encoders/parsers in `Ros2.Common` are growing
ad-hoc; consolidate when you need the third or fourth message type.

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
