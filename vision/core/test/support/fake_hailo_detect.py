#!/usr/bin/env python3
# Stands in for hailo_detect. The HEF file's text picks what it does: "answer"
# replies to each request with one detection spanning the image, "exit" exits
# with status 1 at once, "hang" reads requests and never replies. Each start
# appends a line to <hef>.starts.
import struct, sys

hef = sys.argv[1]
with open(hef + ".starts", "a") as starts:
    starts.write("start\n")
with open(hef) as model:
    mode = model.read().strip()
if mode == "exit":
    sys.exit(1)

while True:
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        break
    request = sys.stdin.buffer.read(struct.unpack(">I", header)[0])
    _tag, sequence, width, height, _channels = struct.unpack("<BIHHB", request[:10])
    if mode == "hang":
        continue
    detection = struct.pack("<Hfffff", 0, 0.9, 0.0, 0.0, float(width), float(height))
    reply = struct.pack("<BIH", 1, sequence, 1) + detection
    sys.stdout.buffer.write(struct.pack(">I", len(reply)) + reply)
    sys.stdout.buffer.flush()
