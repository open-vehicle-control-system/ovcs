# golden_cdr.json — provenance

CDR bodies (no encapsulation header) for the message shapes exercised
by `marker_test.exs` and `detection3d_test.exs`. They are this
codebase's own encoder output, **validated against ROS 2 Jazzy** by
round-tripping through `rclpy.serialization.deserialize_message` and
checking every field came back correct.

## Why not rclpy's bytes directly

The obvious fixture would be `serialize_message` output. It is not
usable as a byte-equality reference: Fast-CDR does not zero its
alignment padding, so the padding bytes are whatever happened to be in
the buffer. A marker serialised by rclpy has `0x97` sitting in the pad
byte after `"detections\0"` on one run and something else on the next.

Length is not a sufficient check either, and this is the trap worth
remembering. A `MarkerArray` element is 245 bytes nested but 249
standalone — starting at offset 4 leaves `action` ending on an
8-boundary, so no padding is needed before `pose` — and CDR then pads
to 4 between elements. Those two effects nearly cancel: an encoder
that does neither produces an array of *exactly the right total
length* in which every element after the first is misaligned. The
only symptom is the receiver reporting "Not enough memory in the
buffer stream".

So the fixture is our bytes, and the thing that made them trustworthy
is deserialisation by the real ROS runtime, not arithmetic.

## Regenerating

Needs the `ovcs-ros2` container running (`ros2/base`, image
`ovcs/ros2:jazzy`) — it carries both `visualization_msgs` and
`vision_msgs`.

1. Encode the fixtures with this repo's modules and dump them as
   hex-keyed JSON (see the `dump.exs` shape in the commit that
   introduced this file).
2. Copy that JSON into the container and, for each entry, prepend the
   4-byte encapsulation header `00 01 00 00` and call
   `deserialize_message` with the matching type. Assert the fields
   match what was encoded — a misaligned buffer either raises or
   returns wrong values.
3. Only once every entry round-trips, write the JSON here.

Type hashes come from `/opt/ros/jazzy/share/<pkg>/msg/<Msg>.json` in
the same container, never from memory, and are per-distro.
