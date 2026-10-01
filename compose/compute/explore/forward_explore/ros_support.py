"""Message conversion and receipt/source-time freshness checks."""

import math
from dataclasses import dataclass

import numpy as np
from forward_explore_core import Grid
from guard_core import fresh
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy

LATCHED = QoSProfile(
    depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL, reliability=ReliabilityPolicy.RELIABLE
)


def seconds(stamp):
    return stamp.sec + stamp.nanosec * 1e-9


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def pose_of(pose):
    return pose.position.x, pose.position.y, yaw_of(pose.orientation)


def to_grid(msg):
    if msg.info.resolution <= 0 or not msg.info.width or not msg.info.height:
        raise ValueError("empty or invalid map")
    data = np.asarray(msg.data, dtype=np.int16).reshape(msg.info.height, msg.info.width)
    origin = msg.info.origin
    return Grid(
        data,
        msg.info.resolution,
        origin.position.x,
        origin.position.y,
        yaw_of(origin.orientation),
    )


@dataclass
class Sample:
    value: object
    stamp: float
    received: float

    def fresh(self, ros_now, now, timeout):
        return fresh(self.stamp, self.received, ros_now, now, timeout)
