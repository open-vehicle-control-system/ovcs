"""Camera viewpoints and conservative grid geometry, independent of ROS."""

import math
from dataclasses import dataclass
from itertools import pairwise

import numpy as np

UNKNOWN = -1
OCCUPIED = 50


def angle_difference(a, b):
    return math.atan2(math.sin(a - b), math.cos(a - b))


def to_frame(pose, forward, lateral):
    x, y, yaw = pose
    return (
        x + math.cos(yaw) * forward - math.sin(yaw) * lateral,
        y + math.sin(yaw) * forward + math.cos(yaw) * lateral,
    )


@dataclass
class Grid:
    data: np.ndarray
    resolution: float
    origin_x: float
    origin_y: float
    origin_yaw: float = 0.0

    def index(self, x, y):
        dx, dy = x - self.origin_x, y - self.origin_y
        c, s = math.cos(self.origin_yaw), math.sin(self.origin_yaw)
        return (
            math.floor((c * dx + s * dy) / self.resolution),
            math.floor((-s * dx + c * dy) / self.resolution),
        )

    def world(self, i, j):
        return to_frame(
            (self.origin_x, self.origin_y, self.origin_yaw),
            (i + 0.5) * self.resolution,
            (j + 0.5) * self.resolution,
        )

    def cell(self, x, y):
        i, j = self.index(x, y)
        if 0 <= j < self.data.shape[0] and 0 <= i < self.data.shape[1]:
            return int(self.data[j, i])
        return UNKNOWN

    @property
    def known_area(self):
        return int(np.count_nonzero(self.data >= 0)) * self.resolution**2


@dataclass(frozen=True)
class Footprint:
    front: float = 0.462
    rear: float = 0.138
    half_width: float = 0.19

    @property
    def corners(self):
        return [
            (x, y) for x in (-self.rear, self.front) for y in (-self.half_width, self.half_width)
        ]


def footprint_cells(grid, pose, footprint):
    """Every grid square intersecting the rectangular footprint (four-axis SAT)."""
    center = to_frame(pose, (footprint.front - footprint.rear) / 2, 0.0)
    dx, dy = center[0] - grid.origin_x, center[1] - grid.origin_y
    co, so = math.cos(grid.origin_yaw), math.sin(grid.origin_yaw)
    cx, cy = co * dx + so * dy, -so * dx + co * dy
    yaw = pose[2] - grid.origin_yaw
    c, s = math.cos(yaw), math.sin(yaw)
    length, width = (footprint.front + footprint.rear) / 2, footprint.half_width
    hx, hy = abs(c) * length + abs(s) * width, abs(s) * length + abs(c) * width
    r = grid.resolution
    i0, i1 = math.floor((cx - hx) / r) - 1, math.floor((cx + hx) / r)
    j0, j1 = math.floor((cy - hy) / r) - 1, math.floor((cy + hy) / r)
    i, j = np.meshgrid(np.arange(i0, i1 + 1), np.arange(j0, j1 + 1))
    x, y = (i + 0.5) * r - cx, (j + 0.5) * r - cy
    padding = r / 2 * (abs(c) + abs(s))
    overlap = (
        (np.abs(x) <= hx + r / 2)
        & (np.abs(y) <= hy + r / 2)
        & (np.abs(c * x + s * y) <= length + padding)
        & (np.abs(-s * x + c * y) <= width + padding)
    )
    return i[overlap], j[overlap]


def footprint_clear(grid, pose, footprint, max_cost=0):
    i, j = footprint_cells(grid, pose, footprint)
    if (
        np.any(i < 0)
        or np.any(j < 0)
        or np.any(i >= grid.data.shape[1])
        or np.any(j >= grid.data.shape[0])
    ):
        return False
    values = grid.data[j, i]
    return bool(np.all((values >= 0) & (values <= max_cost)))


def inside_perimeter(pose, footprint, center, radius):
    return all(math.dist(to_frame(pose, x, y), center) <= radius for x, y in footprint.corners)


def interpolate_path(poses, step, footprint):
    """Bound corner displacement between collision checks, including turning in place."""
    if not poses:
        return
    yield poses[0]
    corner_radius = math.hypot(max(footprint.front, footprint.rear), footprint.half_width)
    for a, b in pairwise(poses):
        dyaw = angle_difference(b[2], a[2])
        n = max(1, math.ceil((math.dist(a[:2], b[:2]) + abs(dyaw) * corner_radius) / step))
        for k in range(1, n + 1):
            t = k / n
            yield (a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), a[2] + t * dyaw)


def path_clear(poses, grid, footprint, center, radius):
    return bool(poses) and all(
        inside_perimeter(p, footprint, center, radius) and footprint_clear(grid, p, footprint)
        for p in interpolate_path(poses, grid.resolution / 2, footprint)
    )


def visible_unknown(grid, camera_pose, left_angle, right_angle, near, far):
    """Area potentially visible, including unknown cells beyond the map boundary."""
    seen = set()
    step = grid.resolution
    for angle in np.arange(-right_angle, left_angle + 1e-9, step / far):
        c, s = math.cos(camera_pose[2] + angle), math.sin(camera_pose[2] + angle)
        for r in np.arange(step / 2, far + step / 2, step):
            x, y = camera_pose[0] + c * r, camera_pose[1] + s * r
            value = grid.cell(x, y)
            if value >= OCCUPIED:
                break
            if r >= near and value == UNKNOWN:
                seen.add(grid.index(x, y))
    return len(seen) * step**2


def viewpoints(grid, pose, footprint, center, perimeter, max_candidates=48):
    """Known-free viewpoints facing frontiers; Nav2 establishes route feasibility."""
    free = grid.data == 0
    unknown = np.pad(grid.data < 0, 1, constant_values=True)
    adjacent = unknown[:-2, 1:-1] | unknown[2:, 1:-1] | unknown[1:-1, :-2] | unknown[1:-1, 2:]
    js, ids = np.nonzero(free & adjacent)
    frontiers = [grid.world(i, j) for i, j in zip(ids, js)]
    frontiers.sort(key=lambda p: math.dist(p, pose[:2]))
    selected, used = [], set()
    for target in frontiers:
        # Cluster boundary cells before evaluating candidate footprints.
        key = (round(target[0] / 0.4), round(target[1] / 0.4))
        if key in used:
            continue
        used.add(key)
        for angle in np.linspace(-math.pi, math.pi, 12, endpoint=False):
            x, y = target[0] - 0.8 * math.cos(angle), target[1] - 0.8 * math.sin(angle)
            view = (x, y, angle)
            if math.dist(view[:2], pose[:2]) < 0.35:
                continue
            if not inside_perimeter(view, footprint, center, perimeter):
                continue
            if footprint_clear(grid, view, footprint):
                selected.append(view)
    # Rank after covering the boundary so nearby side frontiers cannot hide
    # all forward viewpoints before the candidate limit is reached.
    selected.sort(
        key=lambda p: math.dist(p[:2], pose[:2]) + 2 * abs(angle_difference(p[2], pose[2]))
    )
    return selected[:max_candidates]


def motion_poses(pose, linear, angular, horizon, step=0.05):
    n = max(1, math.ceil(horizon / step))
    result = [pose]
    for k in range(1, n + 1):
        t = horizon * k / n
        if abs(angular) < 1e-8:
            x, y = to_frame(pose, linear * t, 0.0)
        else:
            radius, theta = linear / angular, angular * t
            x, y = to_frame(pose, radius * math.sin(theta), radius * (1 - math.cos(theta)))
        result.append((x, y, pose[2] + angular * t))
    return result
