# ros2_zenoh

ROS 2 messages over [Zenoh](https://zenoh.io), without ROS installed: CDR codecs for the standard message types and the [`rmw_zenoh`](https://github.com/ros2/rmw_zenoh) wire format, so an Elixir process with a plain Zenoh session publishes and subscribes to topics that ROS 2 nodes, `ros2 topic echo` and Foxglove see as native.

It is pure Elixir with no runtime dependencies and holds no Zenoh session: the caller brings its own client, such as [`zenohex`](https://github.com/biyooon-ex/zenohex). In OVCS, `RosBridge.ZenohClient` is that client.

## What it covers

| Module | |
|---|---|
| `Ros2Zenoh.<Package>.Msg.<Name>` | One codec per message type: `encode/1` for the CDR body, `parse/1` where a consumer reads it, and `dds_type/0` + `type_hash/0` for publishing |
| `Ros2Zenoh.Common` | The CDR primitives each message module gets with `use Ros2Zenoh.Common`, and their alignment rules |
| `Ros2Zenoh.Cdr` | Lower-level CDR helpers shared by the codecs |
| `Ros2Zenoh.RmwZenoh` | Key expressions, the encapsulation header, publisher attachments and liveliness tokens |
| `Ros2Zenoh.RclInterfaces.Parameters` | The `rcl_interfaces` parameter services, for a node that serves parameters |

The packages are `builtin_interfaces`, `diagnostic_msgs`, `foxglove_msgs`, `geometry_msgs`, `nav_msgs`, `rosgraph_msgs`, `sensor_msgs`, `std_msgs`, `stereo_msgs`, `tf2_msgs`, `vision_msgs` and `visualization_msgs`, each with the message types something here publishes or reads; `lib/ros2_zenoh/` lists them. Type hashes are those of ROS 2 Lyrical.

## The rmw_zenoh wire format

Reaching ROS 2 nodes (Foxglove, `ros2 topic echo`, rclpy) over plain
Zenoh requires three things plain `Zenohex.Publisher.put/3` does not
give you. `Ros2Zenoh.RmwZenoh` builds them:

1. **Data keyexpr** — `<domain>/<topic>/<dds_type>/<type_hash>`.
   Example: `0/heartbeat/std_msgs::msg::dds_::String_/RIHS01_df66…`.
   The DDS type name and RIHS01 hash come from each message module
   (`dds_type/0` + `type_hash/0`); the hash is per-distro and must
   be refreshed if the ROS distro changes — verify against a live
   node with `ros2 topic info -v <topic>` (the "Topic type hash" line).
2. **Payload** — CDR little-endian, prefixed with the encapsulation
   header `00 01 00 00`. Each message module exposes `encode/1`
   producing the CDR body; `Ros2Zenoh.RmwZenoh.encode_payload/1` prepends
   the header.
3. **Publisher attachment** — 33 bytes carrying sequence number
   (i64 LE), source timestamp ns (i64 LE), GID length byte (= 16),
   and a 16-byte GID. Subscribers drop samples without a well-formed
   attachment. `Ros2Zenoh.RmwZenoh.attachment/3` builds it; the GID is
   best generated once per publishing process and reused across
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
`eid` are session-local counters (`0/0` works), and `<qos>` is the
default reliable-volatile profile encoded as `::,:,:,:,,`. Built by
`Ros2Zenoh.RmwZenoh.liveliness_key/5` and registered through
`Zenohex.Liveliness.declare_token/2`. The returned token reference
must stay referenced by the process that declared it — if it's GC'd, the token is
undeclared and the topic disappears from `ros2 topic list`.

## Adding a new ROS message type

1. Drop the codec under `lib/ros2_zenoh/<pkg>/msg/<name>.ex`, as
   `Ros2Zenoh.<Pkg>.Msg.<Name>` with `use Ros2Zenoh.Common`.
2. For **publishing** add three things alongside any existing
   `parse/1`:
   - `def dds_type, do: "<pkg>::msg::dds_::<Name>_"`
   - `def type_hash, do: "RIHS01_<64-hex>"` — copy from
     `ros2 topic info -v` of any live publisher of this type.
   - `def encode(%__MODULE__{...})` returning the CDR-encoded body
     (no encapsulation header — that's added by
     `Ros2Zenoh.RmwZenoh.encode_payload/1`).
3. For **subscribing** only `parse/1` is needed — the rmw_zenoh
   keyexpr is matched on the `<domain>/<topic>/**` wildcard, so the
   message's DDS type name and hash don't have to be hard-coded.
4. Use it: `RmwZenoh.key_expr/3` and `RmwZenoh.encode_payload/1` work
   uniformly across types for the publisher side;
   on the subscriber side, strip the header with
   `RmwZenoh.decode_payload/1` before the message's `parse/1`.

## Tests

`mix test` round-trips every codec that has a `parse/1` and checks the alignment of the encode-only ones. `test/support/golden_cdr.json` holds byte vectors that a real ROS 2 runtime deserialised; `test/support/golden_cdr.md` records how they were produced and how to regenerate them.
