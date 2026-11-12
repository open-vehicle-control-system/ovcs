#!/usr/bin/env python3
# Stands in for qnn_segment. The context binary's text picks what it does:
# "answer" replies to each request with a 4 x 2 label image echoing the request,
# its bytes band_top, band_height, height, width, the first and the last pixel
# byte, the channel count and the request's pixel count modulo 256, and a 2500 us
# inference time; "answer_untimed" the same without the time; "answer_once" the
# same for one request, then exits; "fail" replies with an empty label image;
# "short" with a 4 x 2 label image of 3 bytes;
# "hang" reads requests and never replies; "die" exits with status 1 on its first
# request; "exit" exits with status 1 at once.
# A program that runs logs "ready" first. Each start appends a line to
# <binary>.starts and writes its arguments after the binary to <binary>.arguments.
# It exits when its stdin or its stdout closes. `--graph-names <dlc>` prints the graph
# name "graph" and exits.
import os, struct, sys

if sys.argv[1] == "--graph-names":
    print("graph")
    sys.exit(0)

binary = sys.argv[1]
with open(binary + ".starts", "a") as starts:
    starts.write("start\n")
with open(binary + ".arguments", "w") as arguments:
    arguments.write(" ".join(sys.argv[2:]))
with open(binary) as model:
    mode = model.read().strip()
if mode == "exit":
    sys.exit(1)


def send(record):
    try:
        sys.stdout.buffer.write(struct.pack(">I", len(record)) + record)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        os._exit(0)


send(b"\x02\x00ready")

while True:
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        break
    request = sys.stdin.buffer.read(struct.unpack(">I", header)[0])
    _tag, sequence, width, height, channels, band_top, band_height = struct.unpack(
        "<BIHHBHH", request[:14]
    )
    pixels = request[14:]
    if mode == "hang":
        continue
    if mode == "die":
        sys.exit(1)
    if mode == "fail":
        send(struct.pack("<BIHH", 7, sequence, 0, 0))
        continue
    if mode == "short":
        send(struct.pack("<BIHH", 7, sequence, 4, 2) + bytes(3))
        continue
    labels = bytes(
        [
            band_top % 256,
            band_height % 256,
            height % 256,
            width % 256,
            pixels[0],
            pixels[-1],
            channels,
            len(pixels) // channels % 256,
        ]
    )
    reply = struct.pack("<BIHH", 7, sequence, 4, 2) + labels
    if mode != "answer_untimed":
        reply += struct.pack("<I", 2500)
    send(reply)
    if mode == "answer_once":
        sys.exit(0)
