"""Measure what the stereo pipeline reports, and check it against the world.

The sibling of ``drive_test.py``: that one tests drivetrain geometry
against the model, this one tests perception geometry against the SDF.
Both exist because a pipeline can look perfect on screen while being
wrong by a constant factor — a wheel radius out by 2x, or a disparity
scale out by 16 — and only a number checked against something
independent catches it.

Unlike ``drive_test.py`` this one **asserts and exits non-zero**, so it
can run unattended.

## Where the expected distances come from

Not from a previous run. They are derived from
``worlds/workshop.sdf`` and ``vehicles/ovcs_mini/description/``, so
moving a box or the camera updates the expectation — or fails loudly,
which is the point:

    box_1m     pose x=1.0, 0.3 deep  ->  front face 0.85 m from origin
    box_2m     pose x=2.0, 0.4 deep  ->  front face 1.80 m
    back_wall  pose x=6.0, 0.2 deep  ->  front face 5.90 m

    camera_x = wheelbase/2 - 0.120 = 0.324/2 - 0.120 = 0.042 m

Depth is measured from the lens, so each distance is the world figure
minus ``camera_x``. That gives 0.808 m, 1.758 m and 5.858 m.

## Two kinds of assertion, deliberately different

**Geometry is machine-independent** and checked tightly. If the median
depth is 0.808 m the disparity scale, the rectification and the
intrinsics all agree with the world.

**Throughput is not.** It depends on the CPU, on whether Gazebo is
software-rendering, and on what else is running. Asserting a target
rate here would produce a test that fails on a slower machine while
saying nothing about correctness, so throughput is checked only against
a floor low enough to mean "the pipeline is running at all".

## What it does not test

Detection *quality*. With the stub backend the boxes are fabricated;
with a real model there is no ground truth in this world to score
against. What is checked is that a detection's fused position agrees
with the depth map — the 2D->3D arithmetic — which is the part that was
previously only exercisable on hardware.
"""

import sys
import time

import numpy as np
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image, PointCloud2
from stereo_msgs.msg import DisparityImage
from vision_msgs.msg import Detection3DArray

# From vehicles/ovcs_mini/description/ovcs_mini.urdf.xacro.
WHEELBASE = 0.324
CAMERA_X = WHEELBASE / 2 - 0.120

# From worlds/workshop.sdf: (pose_x, depth_along_x).
BOX_1M = (1.0, 0.3)
BOX_2M = (2.0, 0.4)
BACK_WALL = (6.0, 0.2)


def front_face(pose_x, depth):
    """Distance from the lens to the near face of a box on the x axis."""
    return pose_x - depth / 2 - CAMERA_X


NEAR_BOX = front_face(*BOX_1M)
FAR_BOX = front_face(*BOX_2M)
WALL = front_face(*BACK_WALL)

# Geometry: tight. A centimetre of slack absorbs SGBM quantisation
# (delta_d = 1/16 px) without admitting a scale error.
GEOMETRY_TOLERANCE_M = 0.05
# Throughput: a floor, not a target. See the moduledoc.
MIN_RATE_HZ = 8.0
# Coverage on this world sat at 61% across runs. The band is wide
# enough for renderer differences, narrow enough that a pipeline
# returning almost nothing fails.
COVERAGE_RANGE = (45.0, 80.0)
MEASURE_SECONDS = 20.0


class Probe(Node):
    def __init__(self):
        super().__init__("perception_test")
        self.disparity = []
        self.depth = []
        self.cloud = []
        self.detections = []
        self.create_subscription(DisparityImage, "/stereo/disparity", self.disparity.append, 30)
        self.create_subscription(Image, "/stereo/depth/image_rect", self.depth.append, 30)
        self.create_subscription(PointCloud2, "/stereo/points", self.cloud.append, 30)
        self.create_subscription(
            Detection3DArray, "/stereo/detections", self.detections.append, 30
        )


def rate(messages, elapsed):
    """Hz from unique header stamps.

    Not ``ros2 topic hz``: over this Zenoh fabric it reports wildly
    inflated numbers — 2256 Hz on a 30 Hz topic, observed — because it
    counts deliveries rather than distinct messages. Counting stamps
    also catches a publisher that republishes one frame repeatedly,
    which would otherwise look like a healthy rate.
    """
    stamps = {(m.header.stamp.sec, m.header.stamp.nanosec) for m in messages}
    return len(stamps) / elapsed if elapsed > 0 else 0.0


class Report:
    def __init__(self):
        self.failures = []

    def check(self, ok, label, detail):
        print(f"  {'PASS' if ok else 'FAIL'}  {label}: {detail}")
        if not ok:
            self.failures.append(f"{label}: {detail}")

    def close(self, label, value, expected, tolerance, unit="m"):
        self.check(
            abs(value - expected) <= tolerance,
            label,
            f"{value:.3f} {unit}, world says {expected:.3f} "
            f"(tolerance {tolerance:.3f})",
        )


def main():
    print("Expected from the world, not from a previous run:")
    print(f"  camera_x   {CAMERA_X:.3f} m ahead of base_link")
    print(f"  near box   {NEAR_BOX:.3f} m from the lens")
    print(f"  far box    {FAR_BOX:.3f} m")
    print(f"  back wall  {WALL:.3f} m")
    print()

    rclpy.init()
    node = Probe()

    # Wait for the pipeline rather than assuming it is up: a fresh sim
    # spends a few seconds spawning and the first disparity lags the
    # first camera frame.
    deadline = time.time() + 60
    while time.time() < deadline and not node.depth:
        rclpy.spin_once(node, timeout_sec=0.2)

    if not node.depth:
        print("FAIL  nothing on /stereo/depth/image_rect after 60 s")
        node.destroy_node()
        rclpy.shutdown()
        return 1

    node.disparity.clear()
    node.depth.clear()
    node.cloud.clear()
    node.detections.clear()

    t0 = time.time()
    while time.time() - t0 < MEASURE_SECONDS:
        rclpy.spin_once(node, timeout_sec=0.2)
    elapsed = time.time() - t0

    report = Report()
    print(f"Measured over {elapsed:.1f} s:")

    report.check(
        rate(node.disparity, elapsed) >= MIN_RATE_HZ,
        "disparity rate",
        f"{rate(node.disparity, elapsed):.1f} Hz (floor {MIN_RATE_HZ})",
    )
    report.check(
        rate(node.depth, elapsed) >= MIN_RATE_HZ,
        "depth rate",
        f"{rate(node.depth, elapsed):.1f} Hz (floor {MIN_RATE_HZ})",
    )

    latest = node.depth[-1]
    report.check(
        latest.encoding == "16UC1",
        "depth encoding",
        f"{latest.encoding} (16UC1 millimetres is the ROS convention)",
    )

    raw = np.frombuffer(latest.data, dtype=np.uint16)
    valid = raw[raw > 0]
    coverage = 100.0 * len(valid) / len(raw)
    low, high = COVERAGE_RANGE
    report.check(
        low <= coverage <= high,
        "depth coverage",
        f"{coverage:.1f}% of {latest.width}x{latest.height} (expect {low}-{high}%)",
    )

    if len(valid) == 0:
        print("FAIL  depth frame has no valid pixels; skipping geometry")
        report.failures.append("no valid depth pixels")
    else:
        metres = np.percentile(valid, [50, 75, 95]) / 1000.0
        report.close("depth median", metres[0], NEAR_BOX, GEOMETRY_TOLERANCE_M)
        report.close("depth p75", metres[1], FAR_BOX, GEOMETRY_TOLERANCE_M * 2)
        # The wall bounds the scene: p95 should be approaching it and
        # must not exceed it, which a disparity scale error would.
        report.check(
            metres[2] <= WALL + GEOMETRY_TOLERANCE_M,
            "depth p95 within the room",
            f"{metres[2]:.3f} m, back wall at {WALL:.3f}",
        )

    if node.cloud:
        widths = [c.width for c in node.cloud]
        report.check(
            max(widths) > 0,
            "point cloud",
            f"{max(widths)} points at most, {rate(node.cloud, elapsed):.1f} Hz",
        )
    else:
        print("  SKIP  point cloud: nothing published (cloud_topic unset?)")

    fused = [d for m in node.detections for d in m.detections if d.results]
    if fused:
        zs = [d.results[0].pose.pose.position.z for d in fused]
        # A detection's depth comes from the same map, so it must agree
        # with it. This is the 2D->3D arithmetic under test, not the
        # detector.
        report.close(
            "fused detection depth",
            float(np.median(zs)),
            NEAR_BOX,
            GEOMETRY_TOLERANCE_M,
        )
        print(f"        ({len(fused)} detections, spread {max(zs) - min(zs):.4f} m)")
    else:
        print("  SKIP  detections: none published (no detector configured)")

    node.destroy_node()
    rclpy.shutdown()

    print()
    if report.failures:
        print(f"{len(report.failures)} failure(s):")
        for failure in report.failures:
            print(f"  - {failure}")
        return 1

    print("All perception checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
