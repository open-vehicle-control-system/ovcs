"""Motion checks independent of ROS and the exploration process."""

import math

import forward_explore_core as core
import numpy as np


def fresh(stamp, received, ros_now, now, timeout):
    return stamp > 0 and -0.1 <= ros_now - stamp <= timeout and 0 <= now - received <= timeout


class TraversedCorridor:
    """Recent occupied vehicle space, in odom, for a camera with no rear view."""

    def __init__(self, lifetime=15.0, resolution=0.025):
        self.lifetime = lifetime
        self.grid = core.Grid(np.zeros((1, 1), dtype=np.int8), resolution, 0, 0)
        self.cells = {}

    def prune(self, now):
        self.cells = {
            cell: stamp for cell, stamp in self.cells.items() if now - stamp <= self.lifetime
        }

    def record(self, pose, footprint, now):
        self.prune(now)
        i, j = core.footprint_cells(self.grid, pose, footprint)
        self.cells.update({(int(x), int(y)): now for x, y in zip(i, j)})

    def contains(self, poses, footprint, now):
        self.prune(now)
        for pose in poses:
            i, j = core.footprint_cells(self.grid, pose, footprint)
            if any((int(x), int(y)) not in self.cells for x, y in zip(i, j)):
                return False
        return True


def motion_error(
    grid,
    local_grid,
    map_pose,
    odom_pose,
    footprint,
    origin,
    perimeter,
    linear,
    angular,
    measured_linear,
    measured_angular,
    corridor,
    now,
    reaction_time=0.6,
    deceleration=0.3,
):
    if not all(math.isfinite(v) for v in (linear, angular, measured_linear, measured_angular)):
        return "non-finite velocity"
    # Check the commanded curve and the current motion throughout a conservative stop.
    horizon = reaction_time + max(abs(linear), abs(measured_linear)) / deceleration
    for v, w in ((linear, angular), (measured_linear, measured_angular)):
        mapped = list(core.motion_poses(map_pose, v, w, horizon))
        local = list(core.motion_poses(odom_pose, v, w, horizon))
        if not all(core.inside_perimeter(p, footprint, origin, perimeter) for p in mapped):
            return "perimeter"
        if not all(core.footprint_clear(grid, p, footprint) for p in mapped):
            return "unknown or occupied map footprint"
        if not all(core.footprint_clear(local_grid, p, footprint, max_cost=99) for p in local):
            return "local obstacle or unknown footprint"
        if v < -0.001 and not corridor.contains(local, footprint, now):
            return "reverse leaves recently traversed space"
    return None
