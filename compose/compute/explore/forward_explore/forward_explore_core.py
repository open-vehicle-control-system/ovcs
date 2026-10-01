"""Goal selection for a car that sees ahead only and cannot turn on the spot.

Pure geometry over occupancy grids, no ROS: candidates lie in a cone ahead
of the car, are reachable along one arc no tighter than the car's turning
radius, and are scored by how much unknown space the forward camera would
see from where they end.
"""

import math
from dataclasses import dataclass

import numpy as np

UNKNOWN = -1
OCCUPIED = 50
LETHAL = 100
INSCRIBED = 99


@dataclass
class Grid:
    """An OccupancyGrid's data as a 2-D array, row y, column x."""

    data: np.ndarray
    resolution: float
    origin_x: float
    origin_y: float

    def index(self, x, y):
        return (
            math.floor((x - self.origin_x) / self.resolution),
            math.floor((y - self.origin_y) / self.resolution),
        )

    def cell(self, x, y):
        i, j = self.index(x, y)
        if 0 <= j < self.data.shape[0] and 0 <= i < self.data.shape[1]:
            return int(self.data[j, i])
        return None


@dataclass
class Candidate:
    """A goal in the car's frame."""

    forward: float
    lateral: float


def arc_radius(forward, lateral):
    """Signed radius of the arc from the car, tangent to its heading, through the point."""
    if abs(lateral) < 1e-6:
        return math.inf
    return (forward**2 + lateral**2) / (2.0 * lateral)


def arc_points(forward, lateral, step):
    """Points along that arc, in the car's frame, ending at the point."""
    radius = arc_radius(forward, lateral)
    if math.isinf(radius):
        n = max(int(forward / step), 1)
        return [(forward * k / n, 0.0) for k in range(1, n + 1)]
    sweep = 2.0 * math.atan2(lateral, forward)
    n = max(int(abs(sweep * radius) / step), 1)
    return [
        (radius * math.sin(sweep * k / n), radius * (1.0 - math.cos(sweep * k / n)))
        for k in range(1, n + 1)
    ]


def arc_poses(forward, lateral, step):
    """The arc's points with their tangent heading, relative to the car's."""
    points = arc_points(forward, lateral, step)
    sweep = 0.0 if math.isinf(arc_radius(forward, lateral)) else end_heading(forward, lateral)
    return [(f, lat, sweep * (k + 1) / len(points)) for k, (f, lat) in enumerate(points)]


def end_heading(forward, lateral):
    """Heading at the end of the arc, relative to the car's."""
    return 2.0 * math.atan2(lateral, forward)


def candidates(cone_half_angle, distances, angle_step):
    out = []
    n = round(cone_half_angle / angle_step)
    for distance in distances:
        for k in range(-n, n + 1):
            angle = k * angle_step
            out.append(Candidate(distance * math.cos(angle), distance * math.sin(angle)))
    return out


def to_frame(pose, forward, lateral):
    """A point in the car's frame expressed in the frame `pose` (x, y, yaw) is given in."""
    x, y, yaw = pose
    return (
        x + math.cos(yaw) * forward - math.sin(yaw) * lateral,
        y + math.sin(yaw) * forward + math.cos(yaw) * lateral,
    )


def footprint_clear(costmap, pose, footprint, step):
    """Whether the footprint at `pose` covers no obstacle cell."""
    half_length, half_width = footprint
    for df in np.arange(-half_length, half_length + 1e-9, step):
        for dl in np.arange(-half_width, half_width + 1e-9, step):
            cost = costmap.cell(*to_frame(pose, df, dl))
            if cost is None or cost >= LETHAL:
                return False
    return True


def reverse_arc_poses(distance, radius, step):
    """Poses `distance` back along a circle of signed `radius`, in the car's
    frame: steering left (positive) swings the rear left and the nose right."""
    n = max(int(distance / step), 1)
    out = []
    for k in range(1, n + 1):
        u = distance * k / n
        turn = u / radius
        out.append((-radius * math.sin(turn), radius * (1.0 - math.cos(turn)), -turn))
    return out


def poses_clear(poses, costmap, pose, footprint, step):
    """Whether the footprint is clear at each (forward, lateral, heading) in the car's frame."""
    return all(
        footprint_clear(costmap, (*to_frame(pose, f, lat), pose[2] + heading), footprint, step)
        for f, lat, heading in poses
    )


def chord_poses(forward, lateral, step):
    """The straight line to the point, which a controller cutting the arc follows."""
    distance = math.hypot(forward, lateral)
    heading = math.atan2(lateral, forward)
    n = max(int(distance / step), 1)
    return [(forward * k / n, lateral * k / n, heading) for k in range(1, n + 1)]


def reachable(candidate, costmap, pose, min_radius, footprint, step, sweep_step=0.1):
    """Whether the car can drive there: one arc no tighter than its turning radius,
    with the whole footprint clear of obstacles at every `sweep_step`, along the
    arc and along the chord (its corners sweep wider than its centre, and on a
    short path the controller heads for the goal and cuts the arc)."""
    if abs(arc_radius(candidate.forward, candidate.lateral)) < min_radius:
        return False
    sweep = arc_poses(candidate.forward, candidate.lateral, sweep_step)
    sweep += chord_poses(candidate.forward, candidate.lateral, sweep_step)
    return poses_clear(sweep, costmap, pose, footprint, step)


def seen_free(grid, pose, candidate, skip, step):
    """Whether the arc runs through space the map knows to be free, past the first
    `skip` metres, which the camera cannot see."""
    for f, lat in arc_points(candidate.forward, candidate.lateral, step):
        if math.hypot(f, lat) < skip:
            continue
        if grid.cell(*to_frame(pose, f, lat)) != 0:
            return False
    return True


def visible_unknown(grid, pose, half_fov, near, far, step):
    """Unknown cells a forward camera at `pose` would see, each ray stopped by an obstacle."""
    seen = set()
    for angle in np.arange(-half_fov, half_fov + 1e-9, step / far):
        c, s = math.cos(pose[2] + angle), math.sin(pose[2] + angle)
        for r in np.arange(near, far + 1e-9, step):
            x, y = pose[0] + c * r, pose[1] + s * r
            value = grid.cell(x, y)
            if value is None:
                break
            if value >= OCCUPIED:
                break
            if value == UNKNOWN:
                seen.add(grid.index(x, y))
    return len(seen)


def near_any(goal, places, radius):
    return any(math.hypot(goal[0] - x, goal[1] - y) < radius for (x, y) in places)


def score(goal, gain, visited, radius, penalty):
    """Information gain, less a penalty for each visited place near the goal (x, y)."""
    near = sum(1 for (x, y) in visited if math.hypot(goal[0] - x, goal[1] - y) < radius)
    return gain - penalty * near
