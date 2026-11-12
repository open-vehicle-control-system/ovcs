#!/usr/bin/env python3
# Stands in for hailo_detect. The HEF file's text picks what it does: "answer"
# replies to each request with one detection spanning the image, of class id
# its channel count less one, and a 1500 us inference time, "answer_once" the same for one request, then exits, "answer_untimed" the same without the time, "exit" exits
# with status 1 at once, "die" exits with status 1 on its first request, "hang"
# reads requests and never replies. A program that
# runs logs "ready" first. Each start appends a line to <hef>.starts and writes its
# arguments after the HEF to <hef>.arguments. As qnn_detect, `--graph-names <dlc>`
# prints the graph name "graph" and exits.
import struct, sys

if sys.argv[1] == "--graph-names":
    print("graph")
    sys.exit(0)

hef = sys.argv[1]
with open(hef + ".starts", "a") as starts:
    starts.write("start\n")
with open(hef + ".arguments", "w") as arguments:
    arguments.write(" ".join(sys.argv[2:]))
with open(hef) as model:
    mode = model.read().strip()
if mode == "exit":
    sys.exit(1)

ready = b"\x02\x00ready"
sys.stdout.buffer.write(struct.pack(">I", len(ready)) + ready)
sys.stdout.buffer.flush()

while True:
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        break
    request = sys.stdin.buffer.read(struct.unpack(">I", header)[0])
    _tag, sequence, width, height, channels = struct.unpack("<BIHHB", request[:10])
    if mode == "hang":
        continue
    if mode == "die":
        sys.exit(1)
    detection = struct.pack("<Hfffff", channels - 1, 0.9, 0.0, 0.0, float(width), float(height))
    reply = struct.pack("<BIH", 1, sequence, 1) + detection
    if mode != "answer_untimed":
        reply += struct.pack("<I", 1500)
    sys.stdout.buffer.write(struct.pack(">I", len(reply)) + reply)
    sys.stdout.buffer.flush()
    if mode == "answer_once":
        sys.exit(0)
