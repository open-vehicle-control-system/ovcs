"""Exercise Nav2 lifecycle and sensor-loss stopping in an isolated container."""

import math
import os
import subprocess
import time
import xml.etree.ElementTree as ET
from contextlib import ExitStack
from pathlib import Path

import rclpy
from geometry_msgs.msg import PoseStamped, TransformStamped, TwistStamped
from lifecycle_msgs.srv import ChangeState
from nav2_msgs.action import ComputePathToPose, FollowPath
from nav2_msgs.srv import ClearEntireCostmap
from nav_msgs.msg import Odometry
from rclpy.action import ActionClient
from sensor_msgs.msg import LaserScan, PointCloud2, Range
from sensor_msgs_py.point_cloud2 import create_cloud_xyz32
from std_msgs.msg import Header
from tf2_ros import StaticTransformBroadcaster, TransformBroadcaster

assert os.environ.get("OVCS_NAV2_TEST_CONTAINER") == "1"
rclpy.init()
node = rclpy.create_node("nav2_configuration_test")
processes = []
omitted = set()
commands = []
static_broadcaster = StaticTransformBroadcaster(node)
broadcaster = TransformBroadcaster(node)


def quaternion(rpy):
    roll, pitch, yaw = rpy
    cr, sr = math.cos(roll / 2), math.sin(roll / 2)
    cp, sp = math.cos(pitch / 2), math.sin(pitch / 2)
    cy, sy = math.cos(yaw / 2), math.sin(yaw / 2)
    return (
        sr * cp * cy - cr * sp * sy,
        cr * sp * cy + sr * cp * sy,
        cr * cp * sy - sr * sp * cy,
        cr * cp * cy + sr * sp * sy,
    )


transforms = []
for joint in ET.parse("/review/description/ovcs_mini.urdf").findall("joint"):
    if joint.attrib["type"] != "fixed":
        continue
    transform = TransformStamped()
    transform.header.frame_id = joint.find("parent").attrib["link"]
    transform.child_frame_id = joint.find("child").attrib["link"]
    origin = joint.find("origin")
    xyz = (
        [float(value) for value in origin.attrib.get("xyz", "0 0 0").split()]
        if origin is not None
        else [0.0, 0.0, 0.0]
    )
    rpy = (
        [float(value) for value in origin.attrib.get("rpy", "0 0 0").split()]
        if origin is not None
        else [0.0, 0.0, 0.0]
    )
    (
        transform.transform.translation.x,
        transform.transform.translation.y,
        transform.transform.translation.z,
    ) = xyz
    rotation = transform.transform.rotation
    rotation.x, rotation.y, rotation.z, rotation.w = quaternion(rpy)
    transforms.append(transform)
static_broadcaster.sendTransform(transforms)
scan_publisher = node.create_publisher(LaserScan, "/scan", 10)
cloud_publisher = node.create_publisher(PointCloud2, "/stereo/points", 10)
range_publishers = {
    side: node.create_publisher(Range, "/ultrasound/" + side, 10)
    for side in ["rear_left", "rear_right"]
}
odom_publisher = node.create_publisher(Odometry, "/odom", 10)
node.create_subscription(
    TwistStamped,
    "/cmd_vel_nav",
    lambda message: commands.append((time.monotonic(), message.twist.linear.x)),
    10,
)


def publish_inputs():
    stamp = node.get_clock().now().to_msg()
    transform = TransformStamped()
    transform.header = Header(stamp=stamp, frame_id="odom")
    transform.child_frame_id = "base_link"
    transform.transform.rotation.w = 1.0
    broadcaster.sendTransform(transform)
    odometry = Odometry()
    odometry.header = Header(stamp=stamp, frame_id="odom")
    odometry.child_frame_id = "base_rear_axle"
    odometry.pose.pose.position.x = -0.162
    odometry.pose.pose.orientation.w = 1.0
    odom_publisher.publish(odometry)
    if "scan" not in omitted:
        scan = LaserScan()
        scan.header = Header(stamp=stamp, frame_id="lidar_link")
        scan.angle_min, scan.angle_max = -math.pi, math.pi
        scan.angle_increment = 2 * math.pi / 72
        scan.range_min, scan.range_max = 0.05, 5.0
        scan.ranges = [float("inf")] * 73
        scan_publisher.publish(scan)
    if "stereo" not in omitted:
        cloud_publisher.publish(
            create_cloud_xyz32(Header(stamp=stamp, frame_id="odom"), [(2.0, 1.0, 0.0)])
        )
    for side, publisher in range_publishers.items():
        if side not in omitted:
            reading = Range()
            reading.header = Header(stamp=stamp, frame_id="ultrasound_" + side + "_link")
            reading.field_of_view = 0.5
            reading.min_range, reading.max_range, reading.range = 0.03, 4.5, 4.5
            publisher.publish(reading)


node.create_timer(0.02, publish_inputs)


def spin(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.02)


def await_future(future, seconds=20):
    deadline = time.monotonic() + seconds
    while not future.done() and time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.02)
    assert future.done(), "service/action response timed out"
    return future.result()


def call(service_type, name, request):
    client = node.create_client(service_type, name)
    deadline = time.monotonic() + 20
    while not client.service_is_ready() and time.monotonic() < deadline:
        spin(0.05)
    assert client.service_is_ready(), name + " unavailable"
    response = await_future(client.call_async(request))
    node.destroy_client(client)
    return response


servers = [
    ("nav2_controller", "controller_server"),
    ("nav2_planner", "planner_server"),
    ("nav2_behaviors", "behavior_server"),
    ("nav2_velocity_smoother", "velocity_smoother"),
    ("nav2_bt_navigator", "bt_navigator"),
]
with ExitStack() as logs:
    try:
        for package, executable in servers:
            log = logs.enter_context(open("/tmp/" + executable + ".log", "w"))
            arguments = [
                "/opt/ros/lyrical/lib/" + package + "/" + executable,
                "--ros-args",
                "--params-file",
                "/opt/ovcs/config/nav2.yaml",
                "-r",
                "__node:=" + executable,
            ]
            arguments += ["-r", "cmd_vel:=/cmd_vel_nav_raw"]
            if executable == "velocity_smoother":
                arguments += ["-r", "cmd_vel_smoothed:=/cmd_vel_nav"]
            processes.append(subprocess.Popen(arguments, stdout=log, stderr=subprocess.STDOUT))
        for _, executable in servers:
            for transition in [1, 3]:
                request = ChangeState.Request()
                request.transition.id = transition
                assert call(ChangeState, "/" + executable + "/change_state", request).success, (
                    executable
                )
            print(executable + " active", flush=True)
        spin(1.0)
        planner = ActionClient(node, ComputePathToPose, "/compute_path_to_pose")
        assert planner.wait_for_server(timeout_sec=10)
        plan_goal = ComputePathToPose.Goal()
        plan_goal.goal.header = Header(stamp=node.get_clock().now().to_msg(), frame_id="odom")
        plan_goal.goal.pose.position.x = 1.3
        plan_goal.goal.pose.position.y = 0.4
        plan_goal.goal.pose.orientation.w = 1.0
        plan_goal.planner_id = "GridBased"
        plan_handle = await_future(planner.send_goal_async(plan_goal))
        assert plan_handle.accepted
        plan = await_future(plan_handle.get_result_async()).result
        assert plan.error_code == 0 and len(plan.path.poses) > 1
        assert abs(plan.path.poses[0].pose.position.x + 0.162) < 0.1
        print("Smac plans from the rear-axle pose", flush=True)
        action = ActionClient(node, FollowPath, "/follow_path")
        assert action.wait_for_server(timeout_sec=10)
        for missing in ["scan", "stereo", "rear_left", "rear_right"]:
            omitted.clear()
            spin(0.5)
            for costmap in ["local_costmap", "global_costmap"]:
                call(
                    ClearEntireCostmap,
                    "/" + costmap + "/clear_entirely_" + costmap,
                    ClearEntireCostmap.Request(),
                )
            spin(0.5)
            goal = FollowPath.Goal()
            goal.path.header = Header(stamp=node.get_clock().now().to_msg(), frame_id="odom")
            for index in range(31):
                pose = PoseStamped()
                pose.header = goal.path.header
                pose.pose.position.x = -0.162 + index * 0.05
                pose.pose.orientation.w = 1.0
                goal.path.poses.append(pose)
            goal.controller_id, goal.goal_checker_id = "FollowPath", "goal_checker"
            goal.progress_checker_id, goal.path_handler_id = "progress_checker", "PathHandler"
            commands.clear()
            handle = await_future(action.send_goal_async(goal))
            assert handle.accepted
            deadline = time.monotonic() + 8
            while (
                not any(abs(speed) > 0.02 for _, speed in commands)
                and time.monotonic() < deadline
            ):
                spin(0.05)
            assert any(abs(speed) > 0.02 for _, speed in commands), (
                "no motion before loss of " + missing
            )
            omitted.add(missing)
            lost_at = time.monotonic()
            spin(2.0)
            after_loss = [(at, speed) for at, speed in commands if at > lost_at]
            late_commands = [speed for at, speed in after_loss if at > lost_at + 1.5]
            assert after_loss and abs(after_loss[-1][1]) < 0.001, (missing, after_loss)
            assert all(abs(speed) < 0.001 for speed in late_commands), (missing, late_commands)
            await_future(handle.cancel_goal_async())
            print(missing + " loss stops commands while other sensors continue", flush=True)
        print("Nav2 runtime checks passed", flush=True)
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        for _, executable in servers:
            content = Path("/tmp/" + executable + ".log").read_text()
            print(
                "\n" + executable + " log tail:\n" + "\n".join(content.splitlines()[-14:]),
                flush=True,
            )
        node.destroy_node()
        rclpy.shutdown()
