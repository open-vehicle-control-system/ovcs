"""Exercise the forward explorer's geometry and scoring on synthetic grids."""

import importlib.util
import math
import unittest
from pathlib import Path

import numpy as np

spec = importlib.util.spec_from_file_location(
    "forward_explore_core", Path(__file__).resolve().parents[1] / "forward_explore_core.py"
)
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)

RES = 0.05


def grid(value, size=10.0):
    """A square grid centred on the origin, filled with `value`."""
    n = int(size / RES)
    return core.Grid(np.full((n, n), value, dtype=np.int16), RES, -size / 2, -size / 2)


def fill(g, x0, x1, y0, y1, value):
    i0, j0 = g.index(x0, y0)
    i1, j1 = g.index(x1, y1)
    g.data[j0 : j1 + 1, i0 : i1 + 1] = value


class ArcTest(unittest.TestCase):
    def test_the_arc_ends_on_the_goal_with_the_tangent_heading(self):
        for forward, lateral in ((1.0, 0.4), (1.5, -0.6), (2.0, 0.0)):
            end = core.arc_points(forward, lateral, 0.05)[-1]
            self.assertAlmostEqual(end[0], forward, places=6)
            self.assertAlmostEqual(end[1], lateral, places=6)
        self.assertAlmostEqual(core.end_heading(1.0, 1.0), math.pi / 2)

    def test_arc_poses_turn_steadily_to_the_end_heading(self):
        poses = core.arc_poses(1.0, 0.4, 0.05)
        headings = [h for _, _, h in poses]
        self.assertEqual(headings, sorted(headings))
        self.assertAlmostEqual(headings[-1], core.end_heading(1.0, 0.4))
        self.assertTrue(all(h == 0.0 for _, _, h in core.arc_poses(1.0, 0.0, 0.05)))

    def test_radius_through_a_point(self):
        self.assertAlmostEqual(core.arc_radius(1.0, 1.0), 1.0)
        self.assertAlmostEqual(core.arc_radius(1.0, -1.0), -1.0)
        self.assertTrue(math.isinf(core.arc_radius(1.0, 0.0)))

    def test_candidates_cover_the_cone(self):
        cs = core.candidates(math.radians(60), [1.0], math.radians(30))
        angles = sorted(round(math.degrees(math.atan2(c.lateral, c.forward))) for c in cs)
        self.assertEqual(angles, [-60, -30, 0, 30, 60])


class ReachableTest(unittest.TestCase):
    footprint = (0.30, 0.19)

    def test_straight_ahead_on_a_free_grid(self):
        free = grid(0)
        self.assertTrue(core.reachable(core.Candidate(1.5, 0.0), free, (0, 0, 0), 0.7, self.footprint, 0.05))

    def test_an_arc_tighter_than_the_turning_radius_is_refused(self):
        free = grid(0)
        sharp = core.Candidate(1.0 * math.cos(math.radians(60)), 1.0 * math.sin(math.radians(60)))
        self.assertLess(abs(core.arc_radius(sharp.forward, sharp.lateral)), 0.7)
        self.assertFalse(core.reachable(sharp, free, (0, 0, 0), 0.7, self.footprint, 0.05))

    def test_an_obstacle_on_the_arc_is_refused(self):
        g = grid(0)
        fill(g, 0.75, 0.85, -0.1, 0.1, core.LETHAL)
        self.assertFalse(core.reachable(core.Candidate(1.5, 0.0), g, (0, 0, 0), 0.7, self.footprint, 0.05))

    def test_a_footprint_on_an_obstacle_beside_the_goal_is_refused(self):
        g = grid(0)
        fill(g, 1.4, 1.6, 0.15, 0.2, core.LETHAL)
        self.assertFalse(core.reachable(core.Candidate(1.5, 0.0), g, (0, 0, 0), 0.7, self.footprint, 0.05))

    def test_a_corner_sweeping_into_an_obstacle_is_refused(self):
        # Inside a left turn: the arc's centre line passes 16 cm from it,
        # the left side of the footprint runs over it.
        g = grid(0)
        turn = core.Candidate(1.5 * math.cos(math.radians(40)), 1.5 * math.sin(math.radians(40)))
        fill(g, 0.45, 0.50, 0.25, 0.30, core.LETHAL)
        centre = [g.cell(f, lat) for f, lat in core.arc_points(turn.forward, turn.lateral, 0.05)]
        self.assertTrue(all(c < core.INSCRIBED for c in centre))
        self.assertFalse(core.reachable(turn, g, (0, 0, 0), 0.7, self.footprint, 0.05))

    def test_an_obstacle_on_the_chord_is_refused(self):
        # A controller heading for the goal cuts inside the arc.
        g = grid(0)
        turn = core.Candidate(1.0 * math.cos(math.radians(30)), 1.0 * math.sin(math.radians(30)))
        mid = (turn.forward / 2, turn.lateral / 2)
        fill(g, mid[0], mid[0] + 0.05, mid[1] + 0.12, mid[1] + 0.17, core.LETHAL)
        arc_only = [core.footprint_clear(g, (f, lat, h), self.footprint, 0.05) for f, lat, h in core.arc_poses(turn.forward, turn.lateral, 0.1)]
        self.assertTrue(all(arc_only))
        self.assertFalse(core.reachable(turn, g, (0, 0, 0), 0.7, self.footprint, 0.05))

    def test_the_pose_is_honoured(self):
        g = grid(0)
        fill(g, -0.1, 0.1, 0.75, 0.85, core.LETHAL)
        facing_up = (0.0, 0.0, math.pi / 2)
        self.assertFalse(core.reachable(core.Candidate(1.5, 0.0), g, facing_up, 0.7, self.footprint, 0.05))
        self.assertTrue(core.reachable(core.Candidate(1.5, 0.0), g, (0, 0, 0), 0.7, self.footprint, 0.05))


class ReverseArcTest(unittest.TestCase):
    def test_steering_left_swings_the_rear_left_and_the_nose_right(self):
        f, lat, heading = core.reverse_arc_poses(0.5, 0.7, 0.05)[-1]
        self.assertLess(f, 0.0)
        self.assertGreater(lat, 0.0)
        self.assertAlmostEqual(heading, -0.5 / 0.7)
        self.assertAlmostEqual(math.hypot(f, lat), 2 * 0.7 * math.sin(0.25 / 0.7))

    def test_an_obstacle_behind_on_one_side_blocks_only_that_side(self):
        g = grid(0)
        fill(g, -0.75, -0.65, 0.15, 0.35, core.LETHAL)
        footprint = (0.30, 0.19)
        left = core.reverse_arc_poses(0.5, 0.7, 0.1)
        right = core.reverse_arc_poses(0.5, -0.7, 0.1)
        self.assertFalse(core.poses_clear(left, g, (0, 0, 0), footprint, 0.05))
        self.assertTrue(core.poses_clear(right, g, (0, 0, 0), footprint, 0.05))


class SeenFreeTest(unittest.TestCase):
    def test_unknown_on_the_arc_beyond_the_blind_zone_is_refused(self):
        g = grid(0)
        fill(g, 0.75, 0.85, -0.1, 0.1, core.UNKNOWN)
        self.assertFalse(core.seen_free(g, (0, 0, 0), core.Candidate(1.0, 0.0), 0.6, 0.05))

    def test_unknown_inside_the_blind_zone_is_ignored(self):
        g = grid(0)
        fill(g, 0.0, 0.5, -0.1, 0.1, core.UNKNOWN)
        self.assertTrue(core.seen_free(g, (0, 0, 0), core.Candidate(1.0, 0.0), 0.6, 0.05))


class GainTest(unittest.TestCase):
    def test_counts_unknown_cells_in_view(self):
        g = grid(0)
        fill(g, 1.0, 2.0, -0.2, 0.2, core.UNKNOWN)
        self.assertGreater(core.visible_unknown(g, (0, 0, 0), math.radians(18), 0.55, 3.0, 0.05), 0)
        self.assertEqual(core.visible_unknown(g, (0, 0, math.pi), math.radians(18), 0.55, 3.0, 0.05), 0)

    def test_an_obstacle_hides_what_is_behind_it(self):
        g = grid(0)
        fill(g, 1.5, 2.5, -1.0, 1.0, core.UNKNOWN)
        open_view = core.visible_unknown(g, (0, 0, 0), math.radians(18), 0.55, 3.0, 0.05)
        fill(g, 1.0, 1.05, -1.0, 1.0, core.LETHAL)
        self.assertEqual(core.visible_unknown(g, (0, 0, 0), math.radians(18), 0.55, 3.0, 0.05), 0)
        self.assertGreater(open_view, 0)

    def test_visited_places_lower_the_score(self):
        self.assertEqual(core.score((1.0, 0.0), 40, [], 0.6, 30), 40)
        self.assertEqual(core.score((1.0, 0.0), 40, [(1.2, 0.1), (5.0, 5.0)], 0.6, 30), 10)

    def test_near_any(self):
        self.assertTrue(core.near_any((1.0, 0.0), [(1.2, 0.1)], 0.6))
        self.assertFalse(core.near_any((1.0, 0.0), [(5.0, 5.0)], 0.6))


if __name__ == "__main__":
    unittest.main()
