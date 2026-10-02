"""Regression cases for mapped footprint clearance, visibility and reverse coverage."""

import math
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import forward_explore_core as core
from guard_core import TraversedCorridor, fresh, motion_error


def grid(value=0, size=10.0):
    n = int(size / 0.05)
    return core.Grid(np.full((n, n), value, dtype=np.int16), 0.05, -size / 2, -size / 2)


def fill(g, x, y, value):
    i, j = g.index(x, y)
    g.data[j, i] = value


class GeometryTest(unittest.TestCase):
    def setUp(self):
        self.grid = grid()
        self.footprint = core.Footprint()

    def test_rotated_grid_and_negative_coordinates(self):
        g = core.Grid(np.arange(12).reshape(3, 4), 0.1, 1.0, -2.0, math.pi / 3)
        for j in range(3):
            for i in range(4):
                self.assertEqual(g.index(*g.world(i, j)), (i, j))
                self.assertEqual(g.cell(*g.world(i, j)), j * 4 + i)
        self.assertEqual(core.Grid(np.zeros((2, 2)), 1, 0, 0).index(-0.01, -0.01), (-1, -1))

    def test_obstacle_inside_footprint_but_off_centerline(self):
        fill(self.grid, 0.2, 0.15, 100)
        self.assertFalse(core.footprint_clear(self.grid, (0, 0, 0), self.footprint))

    def test_small_obstacle_inside_polygon_not_just_edges(self):
        fill(self.grid, 0.1, 0.05, 100)
        self.assertFalse(core.footprint_clear(self.grid, (0, 0, 0), self.footprint))

    def test_unknown_and_outside_map_are_not_free(self):
        fill(self.grid, -0.1, -0.1, -1)
        self.assertFalse(core.footprint_clear(self.grid, (0, 0, 0), self.footprint))
        self.assertFalse(core.footprint_clear(self.grid, (5, 0, 0), self.footprint))

    def test_rotated_corner_overlap_is_checked(self):
        pose = (0, 0, math.pi / 4)
        x, y = core.to_frame(pose, 0.44, 0.17)
        fill(self.grid, x, y, 100)
        self.assertFalse(core.footprint_clear(self.grid, pose, self.footprint))

    def test_sweep_finds_obstacle_between_sparse_waypoints(self):
        fill(self.grid, 0.75, 0.15, 100)
        self.assertFalse(
            core.path_clear([(0, 0, 0), (1.5, 0, 0)], self.grid, self.footprint, (0, 0), 4)
        )

    def test_reverse_and_front_corner_respect_perimeter(self):
        self.assertTrue(core.inside_perimeter((3.5, 0, math.pi), self.footprint, (0, 0), 4))
        path = core.motion_poses((3.9, 0, math.pi), -0.12, 0, 4)
        self.assertFalse(core.path_clear(path, self.grid, self.footprint, (0, 0), 4))
        self.assertFalse(core.inside_perimeter((3.8, 0, 0), self.footprint, (0, 0), 4))

    def test_heading_wrap_interpolates_short_rotation(self):
        poses = list(
            core.interpolate_path(
                [(0, 0, math.pi - 0.01), (0, 0, -math.pi + 0.01)], 0.025, self.footprint
            )
        )
        self.assertLess(len(poses), 4)

    def test_known_free_route_is_accepted(self):
        self.assertTrue(
            core.path_clear([(0, 0, 0), (1, 0, 0)], self.grid, self.footprint, (0, 0), 4)
        )

    def test_map_boundary_counts_as_unknown_gain(self):
        self.assertGreater(
            core.visible_unknown(grid(size=2), (0.8, 0, 0), 0.22, 0.38, 0.55, 3), 0
        )

    def test_near_obstacle_occludes_far_unknown(self):
        g = grid(-1)
        g.data[:, 100:110] = 100
        self.assertEqual(core.visible_unknown(g, (0, 0, 0), 0.22, 0.38, 0.55, 3), 0)

    def test_viewpoints_are_fully_free_inside_boundary(self):
        g = grid(-1)
        g.data[60:140, 60:140] = 0
        views = core.viewpoints(g, (0, 0, 0), self.footprint, (0, 0), 3)
        self.assertTrue(views)
        for view in views:
            self.assertTrue(core.footprint_clear(g, view, self.footprint))
            self.assertTrue(core.inside_perimeter(view, self.footprint, (0, 0), 3))


class GuardTest(unittest.TestCase):
    def test_fresh_receipt_does_not_make_old_source_data_fresh(self):
        self.assertFalse(fresh(1, 10, 10, 10, 0.5))
        self.assertFalse(fresh(10, 1, 10, 10, 0.5))
        self.assertFalse(fresh(0, 10, 0, 10, 0.5))
        self.assertFalse(fresh(11, 10, 10, 10, 0.5))
        self.assertTrue(fresh(9.8, 9.9, 10, 10, 0.5))

    def test_unseen_reverse_is_rejected_even_with_free_local_costmap(self):
        reason = motion_error(
            grid(-1),
            grid(),
            (0, 0, 0),
            (0, 0, 0),
            core.Footprint(),
            (0, 0),
            4,
            -0.1,
            0,
            0,
            0,
            TraversedCorridor(),
            1,
        )
        self.assertEqual(reason, "unknown or occupied map footprint")

    def test_mapped_reverse_requires_recent_traversal(self):
        corridor = TraversedCorridor()
        footprint = core.Footprint()
        args = (grid(), grid(), (0, 0, 0), (0, 0, 0), footprint, (0, 0), 4, -0.1, 0, 0, 0)
        self.assertEqual(
            motion_error(*args, corridor, 1), "reverse leaves recently traversed space"
        )
        for x in np.arange(-0.4, 0.05, 0.01):
            corridor.record((x, 0, 0), footprint, 1)
        self.assertIsNone(motion_error(*args, corridor, 2))
        self.assertEqual(
            motion_error(*args, corridor, 17), "reverse leaves recently traversed space"
        )

    def test_reverse_turn_cannot_swing_outside_the_traversed_corridor(self):
        corridor, footprint = TraversedCorridor(), core.Footprint()
        for x in np.arange(-1, 0.1, 0.01):
            corridor.record((x, 0, 0), footprint, 1)
        path = core.motion_poses((0, 0, 0), -0.12, 0.17, 3)
        self.assertFalse(corridor.contains(path, footprint, 2))

    def test_stopping_envelope_includes_current_speed(self):
        g = grid()
        fill(g, 0.65, 0, 100)
        # A zero request cannot erase the vehicle's existing forward momentum.
        reason = motion_error(
            g,
            grid(),
            (0, 0, 0),
            (0, 0, 0),
            core.Footprint(),
            (0, 0),
            4,
            0,
            0,
            0.25,
            0,
            TraversedCorridor(),
            1,
        )
        self.assertEqual(reason, "unknown or occupied map footprint")


if __name__ == "__main__":
    unittest.main()
