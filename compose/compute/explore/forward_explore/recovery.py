"""Short retreats over measured rear-axle poses, never over an intended route."""

import math

import forward_explore_core as core


class DrivenPath:
    def __init__(self, lifetime=15.0):
        self.lifetime = lifetime
        self.samples = []
        self.observed_at = None

    def record(self, pose, now):
        gap = self.observed_at is not None and now - self.observed_at > 0.5
        self.observed_at = now
        self.samples = [(t, p) for t, p in self.samples if now - t <= self.lifetime]
        if self.samples:
            _, last = self.samples[-1]
            distance = math.dist(last[:2], pose[:2])
            forward = (pose[0] - last[0]) * math.cos(last[2]) + (pose[1] - last[1]) * math.sin(
                last[2]
            )
            if distance > 0.15 or forward < -0.005 or gap:
                self.samples = []
            elif distance < 0.005:
                return
        self.samples.append((now, pose))

    def retreat(self, pose, now, distance=0.20):
        samples = [p for t, p in self.samples if now - t <= self.lifetime]
        if not samples or math.dist(pose[:2], samples[-1][:2]) > 0.04:
            return []
        if abs(core.angle_difference(pose[2], samples[-1][2])) > 0.15:
            return []
        path, remaining = [pose], distance
        for target in reversed(samples):
            previous = path[-1]
            length = math.dist(previous[:2], target[:2])
            if length < 1e-6:
                continue
            # Keep the original vehicle headings: the controller drives backwards.
            if length >= remaining:
                fraction = remaining / length
                path.append(
                    (
                        previous[0] + fraction * (target[0] - previous[0]),
                        previous[1] + fraction * (target[1] - previous[1]),
                        previous[2] + fraction * core.angle_difference(target[2], previous[2]),
                    )
                )
                return path
            path.append(target)
            remaining -= length
        return []
