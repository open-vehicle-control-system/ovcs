#!/usr/bin/env python3
# Stands in for jpeg_codec, by a request's last byte: 1 answers "slow"
# after half a second, 2 exits with status 3, 3 answers its process id,
# and any other answers "fast" at once.
import os, struct, sys, time

while True:
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        break
    request = sys.stdin.buffer.read(struct.unpack(">I", header)[0])
    if request.endswith(b"\x01"):
        time.sleep(0.5)
        reply = b"slow"
    elif request.endswith(b"\x02"):
        sys.exit(3)
    elif request.endswith(b"\x03"):
        reply = str(os.getpid()).encode()
    else:
        reply = b"fast"
    try:
        sys.stdout.buffer.write(struct.pack(">I", len(reply)) + reply)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        # The Port was closed before the reply.
        os._exit(0)
