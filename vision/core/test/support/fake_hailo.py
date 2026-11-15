#!/usr/bin/env python3
# Stands in for hailo: `(--detect <hef> <score_threshold> | --segment <hef> <cell_pixels>)...`,
# a request naming its network by index, in that order, and a reply tagged 10 with the index.
# Each HEF file's text picks what its network does with its requests: "answer" replies to
# each, "answer_once" to one then exits, "answer_untimed" without the inference time, "exit"
# exits with status 1 at start, "die" exits with status 1 on its first request, "hang" never
# replies, "unreadable" answers with a packet of an unknown tag, "cut_short" with a reply
# shorter than it says. A detection reply is one detection spanning the image, of class id
# its channel count less one, timed 1500 us; a segmentation reply is the 2x1 label grid
# [0, 1], timed 2500 us. A program that runs logs "ready" first. Each start appends a line to
# <hef>.starts and writes its arguments to <hef>.arguments, for each HEF it is given.
import struct, sys

arguments = sys.argv[1:]
networks = []
for at in range(0, len(arguments), 3):
    flag, hef = arguments[at], arguments[at + 1]
    with open(hef + ".starts", "a") as starts:
        starts.write("start\n")
    with open(hef + ".arguments", "w") as written:
        written.write(" ".join(arguments))
    with open(hef) as model:
        networks.append((flag, model.read().strip()))
if any(mode == "exit" for _flag, mode in networks):
    sys.exit(1)


def write(packet):
    sys.stdout.buffer.write(struct.pack(">I", len(packet)) + packet)
    sys.stdout.buffer.flush()


write(b"\x02\x00ready")

while True:
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        break
    request = sys.stdin.buffer.read(struct.unpack(">I", header)[0])
    index = request[0]
    _tag, sequence = struct.unpack("<BI", request[1:6])
    flag, mode = networks[index]
    if mode == "hang":
        continue
    if mode == "die":
        sys.exit(1)
    if mode == "unreadable":
        write(b"\x09??")
        continue
    if flag == "--detect":
        width, height, channels = struct.unpack("<HHB", request[6:11])
        detection = struct.pack("<Hfffff", channels - 1, 0.9, 0.0, 0.0, float(width), float(height))
        reply = struct.pack("<BIH", 1, sequence, 2 if mode == "cut_short" else 1) + detection
        time_us = 1500
    else:
        labels = b"\x00" if mode == "cut_short" else b"\x00\x01"
        reply = struct.pack("<BIHH", 7, sequence, 2, 1) + labels
        time_us = 2500
    if mode != "answer_untimed" and mode != "cut_short":
        reply += struct.pack("<I", time_us)
    write(bytes([10, index]) + reply)
    if mode == "answer_once":
        sys.exit(0)
