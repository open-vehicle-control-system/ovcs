"""Closed-loop Nav2 checks with an offline Ackermann plant and synthetic perception.

Run in the Nav2 image with --network none. This tests real ROS servers,
controllers, costmaps, supervisor and guard; it does not emulate stereo or CAN.
"""

import argparse
import json
import math
import os
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import rclpy
import yaml
from geometry_msgs.msg import TransformStamped, TwistStamped
from nav_msgs.msg import OccupancyGrid, Odometry
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile
from sensor_msgs.msg import PointCloud2, PointField
from std_msgs.msg import String
from tf2_ros import StaticTransformBroadcaster, TransformBroadcaster

sys.path.insert(0, "/opt/ovcs/forward_explore")
import forward_explore_core as core


class Plant(Node):
    def __init__(self, scenario, controller="FollowPath"):
        super().__init__("offline_ackermann_plant")
        self.scenario = scenario
        self.controller = controller
        self.selector = self.create_publisher(
            String,
            "/controller_selector",
            QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL),
        )
        self.pose = (0.0, 0.0, 0.0)
        self.speed, self.steering = 0.0, 0.0
        self.command = (0.0, 0.0)
        self.command_at = 0.0
        self.last = time.monotonic()
        self.started = self.last
        self.last_sensor = 0.0
        self.last_map = 0.0
        self.distance = self.reverse = self.max_curvature = 0.0
        self.collisions = 0
        self.nonzero = 0
        self.fault = None
        self.guard_reason = None
        self.odom = self.create_publisher(Odometry, "/odom", 10)
        self.cloud = self.create_publisher(PointCloud2, "/stereo/points", 10)
        self.map_publisher = self.create_publisher(
            OccupancyGrid,
            "/rtabmap/map",
            QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL),
        )
        self.mapper = self.create_publisher(String, "/rtabmap/session", 1)
        self.tf = TransformBroadcaster(self)
        self.static = StaticTransformBroadcaster(self)
        self.create_subscription(TwistStamped, "/cmd_vel_nav", self.on_command, 10)
        self.create_subscription(String, "/motion_guard/status", self.on_guard, 10)
        self.grid = core.Grid(np.full((240, 240), -1, dtype=np.int16), 0.05, -6, -6)
        self.truth = core.Grid(np.zeros((240, 240), dtype=np.int16), 0.05, -6, -6)
        # A mapped staging area is required: the camera cannot certify the space under the car.
        self.grid.data[96:145, 100:155] = 0
        self.truth.data[:2, :] = self.truth.data[-2:, :] = 100
        self.truth.data[:, :2] = self.truth.data[:, -2:] = 100
        if scenario == "corridor":
            self.rectangle(1.0, 4.0, 0.8, 1.0)
            self.rectangle(1.0, 4.0, -1.0, -0.8)
        elif scenario == "dead_end":
            self.rectangle(1.0, 3.7, 0.7, 0.9)
            self.rectangle(1.0, 3.7, -0.9, -0.7)
            self.rectangle(3.5, 3.7, -0.9, 0.9)
        self.grid.data[(self.grid.data == 0) & (self.truth.data == 100)] = 100
        self.initial_area = self.grid.known_area
        self.timer = self.create_timer(0.02, self.tick)
        rear = self.transform("base_link", "rear_axle", -0.162, 0, 0)
        camera = self.transform("base_link", "stereo_left", 0.042, 0.045, 0.185)
        camera.transform.rotation.x, camera.transform.rotation.y = -0.5, 0.5
        camera.transform.rotation.z, camera.transform.rotation.w = -0.5, 0.5
        self.static.sendTransform([rear, camera])

    def rectangle(self, x0, x1, y0, y1):
        i0, j0 = self.truth.index(x0, y0)
        i1, j1 = self.truth.index(x1, y1)
        self.truth.data[j0 : j1 + 1, i0 : i1 + 1] = 100

    def transform(self, parent, child, x=0.0, y=0.0, z=0.0, yaw=0.0):
        msg = TransformStamped()
        msg.header.frame_id, msg.child_frame_id = parent, child
        msg.header.stamp = self.get_clock().now().to_msg()
        t = msg.transform
        t.translation.x, t.translation.y, t.translation.z = float(x), float(y), float(z)
        t.rotation.z, t.rotation.w = math.sin(yaw / 2), math.cos(yaw / 2)
        return msg

    def on_command(self, msg):
        v, w = msg.twist.linear.x, msg.twist.angular.z
        assert math.isfinite(v) and math.isfinite(w), "non-finite command"
        assert -0.12001 <= v <= 0.25001, ("speed bound", v)
        assert abs(w) <= abs(v) / 0.6 + 1e-5, ("Ackermann curvature", v, w)
        assert v == 0 or abs(v) >= 0.079, ("deadband", v)
        if abs(v) > 0.001:
            self.nonzero += 1
            self.max_curvature = max(self.max_curvature, abs(w / v))
        self.command, self.command_at = (v, w), time.monotonic()

    def on_guard(self, msg):
        self.guard_reason = json.loads(msg.data)["reason"]

    def tick(self):
        now = time.monotonic()
        dt, self.last = min(now - self.last, 0.1), now
        v, w = self.command if now - self.command_at < 0.3 else (0.0, 0.0)
        desired_steer = math.atan(0.324 * w / v) if abs(v) >= 0.08 else self.steering
        self.steering += max(-dt * 1.0, min(dt * 1.0, desired_steer - self.steering))
        self.speed += max(-dt * 0.6, min(dt * 0.4, v - self.speed))
        # VESC minimum ERPM: a request below the band cannot sustain motion.
        if 0 < abs(v) < 0.08:
            self.speed = 0.0
        angular = self.speed * math.tan(self.steering) / 0.324
        self.pose = core.motion_poses(self.pose, self.speed, angular, dt)[-1]
        self.distance += abs(self.speed) * dt
        self.reverse += max(-self.speed, 0) * dt
        assert core.inside_perimeter(self.pose, core.Footprint(), (0, 0), 4), "left perimeter"
        assert core.footprint_clear(self.truth, self.pose, core.Footprint()), "physical collision"
        x, y = core.to_frame(self.pose, 0.162, 0)
        if self.fault != "odom":
            msg = Odometry()
            msg.header.frame_id, msg.child_frame_id = "odom", "base_link"
            msg.header.stamp = self.get_clock().now().to_msg()
            msg.pose.pose.position.x, msg.pose.pose.position.y = x, y
            msg.pose.pose.orientation.z, msg.pose.pose.orientation.w = (
                math.sin(self.pose[2] / 2),
                math.cos(self.pose[2] / 2),
            )
            msg.twist.twist.linear.x = self.speed
            msg.twist.twist.linear.y = 0.162 * angular
            msg.twist.twist.angular.z = angular
            self.odom.publish(msg)
        if self.fault != "tf":
            self.tf.sendTransform(
                [
                    self.transform("odom", "base_link", x, y, yaw=self.pose[2]),
                    self.transform("map", "odom"),
                ]
            )
        if now - self.last_sensor >= 0.1:
            self.last_sensor = now
            if self.fault != "cloud":
                self.perceive()
        if now - self.last_map >= 0.5:
            self.last_map = now
            self.selector.publish(String(data=self.controller))
            if self.fault != "map":
                msg = OccupancyGrid()
                msg.header.frame_id, msg.header.stamp = "map", self.get_clock().now().to_msg()
                msg.info.resolution, msg.info.width, msg.info.height = 0.05, 240, 240
                msg.info.origin.position.x = msg.info.origin.position.y = -6.0
                msg.info.origin.orientation.w = 1.0
                msg.data = self.grid.data.flatten().tolist()
                self.map_publisher.publish(msg)
            self.mapper.publish(
                String(
                    data=json.dumps(
                        {"id": "fixture", "stamp": self.get_clock().now().nanoseconds * 1e-9}
                    )
                )
            )

    def perceive(self):
        points = []
        camera = (*core.to_frame(self.pose, 0.204, 0.045), self.pose[2])
        for angle in np.linspace(-0.38, 0.22, 97):
            for distance in np.arange(0.55, 3.0, 0.025):
                forward, left = distance * math.cos(angle), distance * math.sin(angle)
                world = core.to_frame(camera, forward, left)
                i, j = self.grid.index(*world)
                if not 0 <= i < 240 or not 0 <= j < 240:
                    break
                occupied = self.truth.data[j, i] == 100
                self.grid.data[j, i] = 100 if occupied else 0
                if occupied or int(distance * 20) % 5 == 0:
                    height = 0.15 if occupied else 0.0
                    points.append((-left, 0.185 - height, forward))
                if occupied:
                    break
        msg = PointCloud2()
        msg.header.frame_id, msg.header.stamp = "stereo_left", self.get_clock().now().to_msg()
        msg.height, msg.width = 1, len(points)
        msg.fields = [
            PointField(name=name, offset=offset, datatype=PointField.FLOAT32, count=1)
            for name, offset in (("x", 0), ("y", 4), ("z", 8))
        ]
        msg.point_step, msg.row_step, msg.is_dense = 12, 12 * len(points), True
        msg.data = b"".join(struct.pack("<fff", *point) for point in points)
        self.cloud.publish(msg)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", choices=["open", "corridor", "dead_end"], default="open")
    parser.add_argument("--controller", choices=["FollowPath", "MPPI"], default="FollowPath")
    parser.add_argument("--duration", type=float, default=100)
    parser.add_argument("--fault", choices=["cloud", "odom", "tf", "map", "explorer"])
    parser.add_argument("--during-retreat", action="store_true")
    args = parser.parse_args()
    rclpy.init()
    plant = Plant(args.scenario, args.controller)
    processes, logs = [], []
    try:

        def start(name, command):
            log = open(f"/tmp/{name}.log", "w")  # noqa: SIM115 - closed after child processes exit
            logs.append(log)
            process = subprocess.Popen(
                command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
            )
            processes.append(process)
            return process

        params = yaml.safe_load(Path("/opt/ovcs/config/nav2.yaml").read_text())
        params["controller_server"]["ros__parameters"]["controller_plugins"] = [
            args.controller,
            "Retreat",
        ]
        Path("/tmp/nav2-test.yaml").write_text(yaml.safe_dump(params))
        nav = start(
            "nav2",
            [
                "ros2",
                "launch",
                "/opt/ovcs/launch/nav2.launch.py",
                "params_file:=/tmp/nav2-test.yaml",
            ],
        )
        explorer = None
        moving_at = None
        injected = None
        injected_distance = None
        stopped_at = None
        report_at = time.monotonic() + 10
        deadline = time.monotonic() + args.duration
        while time.monotonic() < deadline:
            rclpy.spin_once(plant, timeout_sec=0.01)
            if time.monotonic() >= report_at:
                print(
                    json.dumps(
                        {
                            "pose": plant.pose,
                            "distance": plant.distance,
                            "guard": plant.guard_reason,
                        }
                    ),
                    flush=True,
                )
                report_at = time.monotonic() + 10
            if nav.poll() is not None:
                raise AssertionError("Nav2 exited; inspect /tmp/nav2.log")
            if (
                explorer is None
                and "Managed nodes are active" in Path("/tmp/nav2.log").read_text()
            ):
                explorer = start(
                    "explorer", ["python3", "/opt/ovcs/forward_explore/forward_explore_node.py"]
                )
            if plant.nonzero and moving_at is None:
                moving_at = time.monotonic()
            inject_now = (
                plant.speed < -0.08
                if args.during_retreat
                else (moving_at is not None and time.monotonic() - moving_at > 3)
            )
            if args.fault and inject_now and injected is None:
                injected = time.monotonic()
                injected_distance = plant.distance
                if args.fault == "explorer":
                    os.killpg(explorer.pid, signal.SIGKILL)
                else:
                    plant.fault = args.fault
            if (
                injected
                and stopped_at is None
                and plant.command == (0.0, 0.0)
                and abs(plant.speed) < 0.01
            ):
                stopped_at = time.monotonic()
            if injected and time.monotonic() - injected > (4.0 if args.fault == "map" else 1.5):
                assert plant.command == (0.0, 0.0), (
                    "fault did not stop motion",
                    args.fault,
                    plant.command,
                )
                assert abs(plant.speed) < 0.01, ("plant did not stop", plant.speed)
                break
            if explorer and explorer.poll() is not None and not args.fault:
                break
        assert explorer is not None, "Nav2 lifecycle did not activate"
        assert plant.nonzero > 10, ("no sustained motion", plant.guard_reason)
        assert plant.reverse <= 1.05, ("reverse budget", plant.reverse)
        if args.fault:
            assert injected is not None, "fault was never injected during motion"
        else:
            explorer_log = Path("/tmp/explorer.log").read_text()
            assert "Viewpoint reached" in explorer_log, "no completed viewpoint"
            assert plant.distance > 0.5, ("insufficient exploration motion", plant.distance)
            assert plant.grid.known_area - plant.initial_area > 0.5, "no map growth"
            if args.scenario == "dead_end":
                assert "Short retreat completed" in explorer_log, "retreat did not reach its goal"
                assert 0.15 <= plant.reverse <= 0.25, ("short reverse distance", plant.reverse)
                assert explorer_log.count("Short retreat 1:") == 1, "retreat not attempted once"
                assert "Short retreat 2:" not in explorer_log, "repeated reverse without progress"
        print(
            json.dumps(
                {
                    "scenario": args.scenario,
                    "controller": args.controller,
                    "fault": args.fault,
                    "distance": plant.distance,
                    "reverse": plant.reverse,
                    "map_growth": plant.grid.known_area - plant.initial_area,
                    "max_curvature": plant.max_curvature,
                    "last_guard_reason": plant.guard_reason,
                    "stop_delay": stopped_at - injected if stopped_at else None,
                    "stop_distance": plant.distance - injected_distance
                    if injected is not None
                    else None,
                }
            )
        )
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
        for process in reversed(processes):
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        for log in logs:
            log.close()
        plant.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
