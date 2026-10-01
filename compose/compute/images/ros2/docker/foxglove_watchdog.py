"""Exit when foxglove_bridge stops reading its Zenoh session.

A client that leaves its session undrained fills the router's queue
towards it, and the router then stalls graph discovery for every node.
Exiting restarts the service, which opens a fresh session.
"""

import argparse
import logging
import os
import re
import sys
import time

LOG = logging.getLogger("foxglove_watchdog")
SOCKET_LINK = re.compile(r"^socket:\[(\d+)\]$")


def socket_inodes(pid, proc="/proc"):
    inodes = set()
    fd_dir = os.path.join(proc, str(pid), "fd")
    for fd in os.listdir(fd_dir):
        try:
            match = SOCKET_LINK.match(os.readlink(os.path.join(fd_dir, fd)))
        except OSError:
            continue
        if match:
            inodes.add(match.group(1))
    return inodes


def unread_bytes(pid, router_port, proc="/proc"):
    """Bytes waiting in `pid`'s receive queues on its TCP connections to `router_port`."""
    inodes = socket_inodes(pid, proc)
    port_suffix = f":{router_port:04X}"
    total = 0
    for table in ("tcp", "tcp6"):
        try:
            with open(os.path.join(proc, "net", table)) as rows:
                next(rows)
                for row in rows:
                    fields = row.split()
                    if fields[2].endswith(port_suffix) and fields[9] in inodes:
                        total += int(fields[4].split(":")[1], 16)
        except FileNotFoundError:
            continue
    return total


def watch(pid, router_port, max_unread, stall_s, interval_s, proc="/proc", sleep=time.sleep):
    stalled_s = 0.0
    while True:
        sleep(interval_s)
        unread = unread_bytes(pid, router_port, proc)
        stalled_s = stalled_s + interval_s if unread > max_unread else 0.0
        if stalled_s >= stall_s:
            LOG.error("%d bytes unread from the Zenoh router for %.0f s; restarting", unread, stalled_s)
            return


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--router-port", type=int, default=7447)
    parser.add_argument("--max-unread-bytes", type=int, default=1_000_000)
    parser.add_argument("--stall-seconds", type=float, default=10.0)
    parser.add_argument("--interval-seconds", type=float, default=1.0)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")
    watch(args.pid, args.router_port, args.max_unread_bytes, args.stall_seconds, args.interval_seconds)
    sys.exit(1)
