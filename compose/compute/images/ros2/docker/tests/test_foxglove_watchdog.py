"""Exercise the watchdog against a fake /proc."""

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "foxglove_watchdog", Path(__file__).resolve().parents[1] / "foxglove_watchdog.py"
)
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)

HEADER = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"


def row(remote_port, rx_queue, inode):
    return (
        f"   0: 0100007F:C82A 0100007F:{remote_port:04X} 01 00000000:{rx_queue:08X}"
        f" 00:00000000 00000000     0        0 {inode} 1\n"
    )


class WatchdogTest(unittest.TestCase):
    def setUp(self):
        self.proc = tempfile.mkdtemp()
        fd_dir = os.path.join(self.proc, "42", "fd")
        os.makedirs(fd_dir)
        os.makedirs(os.path.join(self.proc, "net"))
        os.symlink("socket:[1001]", os.path.join(fd_dir, "3"))
        os.symlink("/dev/null", os.path.join(fd_dir, "4"))

    def write_tcp(self, *rows):
        with open(os.path.join(self.proc, "net", "tcp"), "w") as table:
            table.write(HEADER + "".join(rows))

    def test_counts_only_the_process_sockets_to_the_router(self):
        self.write_tcp(
            row(7447, 6_000_000, 1001),
            row(7447, 500_000, 2002),
            row(8766, 300_000, 1001),
        )
        self.assertEqual(watchdog.unread_bytes(42, 7447, self.proc), 6_000_000)

    def test_returns_once_the_backlog_outlasts_the_stall_window(self):
        self.write_tcp(row(7447, 2_000_000, 1001))
        ticks = []
        watchdog.watch(42, 7447, 1_000_000, 3, 1, self.proc, sleep=ticks.append)
        self.assertEqual(len(ticks), 3)

    def test_a_drained_queue_resets_the_stall_window(self):
        queues = iter([2_000_000, 2_000_000, 0, 2_000_000, 2_000_000, 2_000_000])

        def sleep(_):
            self.write_tcp(row(7447, next(queues), 1001))

        watchdog.watch(42, 7447, 1_000_000, 3, 1, self.proc, sleep=sleep)
        self.assertRaises(StopIteration, next, queues)


if __name__ == "__main__":
    unittest.main()
