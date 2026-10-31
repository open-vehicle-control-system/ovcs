#!/usr/bin/env python3
# Stands in for jpeg_codec: answers a request whose last byte is 1 with
# "slow", after a delay longer than the test's timeout, and any other
# request with "fast" at once.
import struct, sys, time

while True:
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        break
    request = sys.stdin.buffer.read(struct.unpack(">I", header)[0])
    if request.endswith(b"\x01"):
        time.sleep(0.5)
        reply = b"slow"
    else:
        reply = b"fast"
    sys.stdout.buffer.write(struct.pack(">I", len(reply)) + reply)
    sys.stdout.buffer.flush()
