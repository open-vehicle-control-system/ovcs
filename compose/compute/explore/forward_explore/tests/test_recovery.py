"""Retreats need a continuous, recent route that was actually driven."""

import math
import sys
import unittest
from itertools import pairwise
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import forward_explore_core as core
from recovery import DrivenPath


class RecoveryTest(unittest.TestCase):
    def history(self, angular=0.0):
        history = DrivenPath()
        poses = core.motion_poses((0, 0, 0), 0.2, angular, 2.0)
        for i, pose in enumerate(poses):
            history.record(pose, i * 0.05)
        return history, poses[-1]

    def test_retreat_retraces_a_curve_with_original_headings(self):
        history, pose = self.history(0.2)
        path = history.retreat(pose, 2.1)
        self.assertAlmostEqual(sum(math.dist(a[:2], b[:2]) for a, b in pairwise(path)), 0.20)
        self.assertEqual(path[0], pose)
        self.assertLess(path[-1][0], pose[0])
        self.assertLess(path[-1][2], pose[2])
        self.assertLess(abs(path[-1][2]), 0.3)

    def test_stationary_wait_does_not_erase_or_refresh_old_route(self):
        history, pose = self.history()
        for i in range(1, 21):
            history.record(pose, 2 + i * 0.1)
        self.assertTrue(history.retreat(pose, 4.0))
        self.assertFalse(history.retreat(pose, 18.0))

    def test_missing_short_or_disconnected_history_refuses_retreat(self):
        self.assertEqual(DrivenPath().retreat((0, 0, 0), 0), [])
        history, pose = self.history()
        self.assertEqual(history.retreat((pose[0] + 0.1, 0, 0), 2.1), [])
        history.record((1, 0, 0), 2.1)
        self.assertEqual(history.retreat((1, 0, 0), 2.1), [])

    def test_reverse_or_gap_cannot_extend_the_forward_history(self):
        for pose, stamp in (((0.3, 0, 0), 2.1), ((0.41, 0, 0), 3.0)):
            history, _ = self.history()
            history.record(pose, stamp)
            self.assertEqual(history.retreat(pose, stamp), [])
