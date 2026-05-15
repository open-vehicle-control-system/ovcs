defmodule Ros2.RmwZenoh do
  @moduledoc """
  Wire-format helpers for talking to ROS 2 nodes via `rmw_zenoh`.

  Handles the three things `rmw_zenoh` requires that raw Zenoh `put`s
  don't give you:

  1. **Keyexpr** — `<domain_id>/<topic>/<dds_type>/<type_hash>`. See
     https://github.com/ros2/rmw_zenoh/blob/jazzy/docs/design.md.
  2. **Payload** wrapped with the standard CDR encapsulation header
     `00 01 00 00` (CDR little-endian, no options).
  3. **Attachment** carrying the publisher's sequence number, source
     timestamp (ns since epoch), and 16-byte GID. rmw_zenoh
     subscribers drop samples without a well-formed attachment.

  Each ROS message module under `Ros2.*` is expected to expose
  `dds_type/0`, `type_hash/0`, and `encode/1` so this module can
  pack it without per-type knowledge.
  """

  # CDR_LE, no options — all rmw_zenoh payloads use this.
  @cdr_header <<0x00, 0x01, 0x00, 0x00>>

  @doc """
  Builds the rmw_zenoh keyexpr for a topic. Strips the leading `/`
  from the topic to match the format rmw_zenoh's C++ side emits.
  """
  def key_expr(domain_id, topic, msg_module) do
    topic = String.trim_leading(topic, "/")
    "#{domain_id}/#{topic}/#{msg_module.dds_type()}/#{msg_module.type_hash()}"
  end

  @doc """
  CDR-encodes a message and prepends the encapsulation header. Result
  goes straight into `Zenohex.Publisher.put/3` as the payload.
  """
  def encode_payload(%mod{} = msg), do: @cdr_header <> mod.encode(msg)

  @doc """
  Builds the publisher attachment per the rmw_zenoh design doc:
  8 bytes seq (i64 LE), 8 bytes source_timestamp ns (i64 LE),
  1 byte GID length (always 16), 16 bytes GID. 33 bytes total.
  """
  def attachment(sequence_number, source_timestamp_ns, <<_::binary-size(16)>> = gid) do
    <<sequence_number::little-signed-integer-size(64),
      source_timestamp_ns::little-signed-integer-size(64),
      16::unsigned-integer-size(8),
      gid::binary>>
  end

  @doc "Generates a fresh 16-byte publisher GID."
  def random_gid, do: :crypto.strong_rand_bytes(16)

  @doc """
  Builds the rmw_zenoh **liveliness token** keyexpr for a publisher.
  Subscribers (graph cache, `foxglove_bridge`, `ros2 topic list`)
  discover topics by subscribing to `@ros2_lv/**`; without this token,
  our publisher is invisible to graph introspection even though its
  data flows on the right keyexpr.

  Format (verified by capturing live tokens from rclpy publishers):

      @ros2_lv/<domain>/<zid>/<nid>/<eid>/MP/<enclave>/<ns>/<node>/<topic>/<type>/<hash>/<qos>

  Where `/` in enclave / namespace / topic is mangled to `%`. `nid`
  and `eid` are session-local counters; we hardcode `0/0` for our
  single publisher. `<qos>` is the default reliable-volatile profile
  (`::,:,:,:,,`) — matches what rclpy emits with `qos_profile_default`.
  """
  def liveliness_key(domain_id, zid, node_name, topic, msg_module) do
    enclave = mangle("/")
    namespace = mangle("/")
    topic_m = mangle(topic_with_leading_slash(topic))
    nid = 0
    eid = 0
    qos = "::,:,:,:,,"

    "@ros2_lv/#{domain_id}/#{zid}/#{nid}/#{eid}/MP/#{enclave}/#{namespace}/" <>
      "#{node_name}/#{topic_m}/#{msg_module.dds_type()}/#{msg_module.type_hash()}/#{qos}"
  end

  defp mangle(s), do: String.replace(s, "/", "%")
  defp topic_with_leading_slash("/" <> _ = t), do: t
  defp topic_with_leading_slash(t), do: "/" <> t
end
