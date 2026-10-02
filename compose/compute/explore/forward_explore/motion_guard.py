"""Last ROS velocity publisher: expiring authorization and independent motion checks."""

import json
import math
import time

import forward_explore_core as core
import rclpy
import tf2_ros
from geometry_msgs.msg import TwistStamped
from guard_core import TraversedCorridor, fresh, motion_error
from nav_msgs.msg import OccupancyGrid, Odometry
from rclpy.clock import Clock, ClockType
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from rclpy.time import Time
from ros_support import LATCHED, Sample, seconds, to_grid, yaw_of
from sensor_msgs.msg import PointCloud2
from std_msgs.msg import String


class MotionGuard(Node):
    def __init__(self):
        super().__init__("motion_guard")
        p = self.declare_parameter
        self.footprint = core.Footprint(
            p("front", 0.462).value, p("rear", 0.138).value, p("half_width", 0.19).value
        )
        self.max_speed = p("max_speed", 0.25).value
        self.reverse_speed = p("reverse_speed", 0.12).value
        self.radius = p("min_turning_radius", 0.6).value
        self.reverse_budget = p("reverse_budget", 1.0).value
        self.max_duration = p("max_duration", 600.0).value
        self.perimeter_limit = p("perimeter", 4.0).value
        self.map_timeout = p("map_timeout", 3.0).value
        self.deceleration = p("stopping_deceleration", 0.3).value
        self.reaction = p("reaction_time", 0.6).value
        self.tf = tf2_ros.Buffer()
        self.listener = tf2_ros.TransformListener(self.tf, self)
        self.samples = {}
        self.fault = None
        self.lease = None
        self.mission = None
        self.map_session = None
        self.map_epoch_stamp = 0.0
        self.started = None
        self.reverse_distance = 0.0
        self.retreat_id = 0
        self.retreat_started = None
        self.retreat_start_distance = 0.0
        self.last_pose = None
        self.last_map_odom = None
        self.corridor = TraversedCorridor()
        self.output = self.create_publisher(TwistStamped, "/cmd_vel_nav", 10)
        self.status = self.create_publisher(String, "/motion_guard/status", 10)
        self.create_subscription(String, "/rtabmap/session", self.on_map_session, 1)
        self.create_subscription(String, "/forward_explore/lease", self.on_lease, 1)
        self.create_subscription(TwistStamped, "/cmd_vel_nav_smoothed", self.on_command, 1)
        self.create_subscription(Odometry, "/odom", self.on_odom, qos_profile_sensor_data)
        self.create_subscription(
            PointCloud2, "/stereo/points", self.on_cloud, qos_profile_sensor_data
        )
        self.create_subscription(OccupancyGrid, "/rtabmap/map", self.on_map, LATCHED)
        self.create_subscription(OccupancyGrid, "/local_costmap/costmap", self.on_local, LATCHED)
        self.timer = self.create_timer(
            0.05, self.tick, clock=Clock(clock_type=ClockType.STEADY_TIME)
        )

    def sample(self, key, msg, value):
        stamp = seconds(msg.header.stamp)
        previous = self.samples.get(key)
        # Replayed measurements cannot refresh receipt freshness, even with a frozen ROS clock.
        if previous is None or stamp != previous.stamp:
            self.samples[key] = Sample(value, stamp, time.monotonic())

    def on_map_session(self, msg):
        try:
            data = json.loads(msg.data)
            if not isinstance(data["id"], str) or not data["id"]:
                raise ValueError("invalid mapper session")
            if self.map_session != data["id"]:
                if self.map_session:
                    self.fault = "mapper restarted; restart exploration"
                self.map_epoch_stamp = float(data["stamp"])
                self.samples.pop("map", None)
                self.samples.pop("local", None)
            self.map_session = data["id"]
            self.samples["mapper"] = Sample(data["id"], float(data["stamp"]), time.monotonic())
        except (ValueError, TypeError, KeyError):
            self.samples.pop("mapper", None)

    def on_command(self, msg):
        self.sample("command", msg, msg.twist)

    def on_odom(self, msg):
        if msg.header.frame_id != "odom" or msg.child_frame_id != "base_link":
            self.samples.pop("odom", None)
            return
        self.sample("odom", msg, msg.twist.twist)

    def on_cloud(self, msg):
        if not msg.width * msg.height or not msg.data:
            self.samples.pop("cloud", None)
            return
        self.sample("cloud", msg, True)

    def on_map(self, msg):
        try:
            if msg.header.frame_id != "map":
                raise ValueError("map frame")
            if seconds(msg.header.stamp) < self.map_epoch_stamp - 0.1:
                return
            grid = to_grid(msg)
            previous = self.samples.get("map")
            if previous and (
                grid.known_area < previous.value.known_area * 0.7
                or seconds(msg.header.stamp) < previous.stamp - 0.1
            ):
                self.fault = "map reset; restart exploration"
            self.sample("map", msg, grid)
        except (ValueError, TypeError):
            self.samples.pop("map", None)

    def on_local(self, msg):
        try:
            if msg.header.frame_id != "odom":
                raise ValueError("local costmap frame")
            self.sample("local", msg, to_grid(msg))
        except (ValueError, TypeError):
            self.samples.pop("local", None)

    def on_lease(self, msg):
        now = time.monotonic()
        ros_now = self.get_clock().now().nanoseconds * 1e-9
        try:
            data = json.loads(msg.data)
            data.setdefault("mode", "forward")
            data.setdefault("retreat", 0)
            if (
                not isinstance(data["enabled"], bool)
                or not isinstance(data["mission"], str)
                or len(data["origin"]) != 2
                or not data["mission"]
                or data["mode"] not in ("forward", "retreat")
                or type(data["retreat"]) is not int
                or not all(
                    math.isfinite(v) for v in (*data["origin"], data["stamp"], data["perimeter"])
                )
                or not 0 < data["perimeter"] <= self.perimeter_limit
                or not fresh(data["stamp"], now, ros_now, now, 0.5)
            ):
                raise ValueError("invalid lease")
            if data["mission"] != self.mission:
                if (
                    self.lease
                    and self.lease.fresh(ros_now, now, 0.5)
                    and self.lease.value["enabled"]
                ):
                    self.fault = "conflicting mission authorization"
                    return
                odom = self.samples.get("odom")
                if self.mission and odom and abs(odom.value.linear.x) > 0.02:
                    return
                # A new mission is explicit; a heartbeat cannot renew budgets.
                self.mission = data["mission"]
                self.mission_origin = data["origin"]
                self.mission_perimeter = data["perimeter"]
                self.started = now
                self.reverse_distance = 0.0
                self.retreat_id = 0
                self.retreat_started = None
                self.retreat_start_distance = 0.0
                self.fault = None
                self.last_pose = None
                self.last_map_odom = None
                self.corridor = TraversedCorridor()
            elif (
                data["origin"] != self.mission_origin
                or data["perimeter"] != self.mission_perimeter
            ):
                raise ValueError("mission boundary changed")
            if data["enabled"] and data["mode"] == "retreat":
                identity = data["retreat"]
                if not 1 <= identity <= 3 or identity < self.retreat_id:
                    raise ValueError("invalid retreat identity")
                if identity != self.retreat_id:
                    odom = self.samples.get("odom")
                    if (
                        identity != self.retreat_id + 1
                        or odom is None
                        or not odom.fresh(ros_now, now, 0.3)
                        or abs(odom.value.linear.x) > 0.02
                    ):
                        raise ValueError("retreat requires standstill")
                    self.retreat_id = identity
                    self.retreat_started = now
                    self.retreat_start_distance = self.reverse_distance
            self.lease = Sample(data, data["stamp"], now)
        except (ValueError, TypeError, KeyError):
            self.lease = None

    def pose(self, frame, child="rear_axle"):
        transform = self.tf.lookup_transform(frame, child, Time())
        ros_now = self.get_clock().now().nanoseconds * 1e-9
        stamp = seconds(transform.header.stamp)
        if not -0.1 <= ros_now - stamp <= 0.5 or (
            frame == "map" and stamp < self.map_epoch_stamp - 0.1
        ):
            raise ValueError("stale transform")
        t = transform.transform
        return t.translation.x, t.translation.y, yaw_of(t.rotation)

    def health(self, now, ros_now):
        for key, timeout in (
            ("odom", 0.3),
            ("cloud", 0.5),
            ("map", self.map_timeout),
            ("local", 0.5),
            ("mapper", 1.5),
        ):
            sample = self.samples.get(key)
            if sample is None or not sample.fresh(ros_now, now, timeout):
                return f"stale or missing {key}"
        return None

    def evaluate(self, now, ros_now):
        error = self.health(now, ros_now)
        if error:
            return error
        try:
            mapped, odom = self.pose("map"), self.pose("odom")
            map_odom = self.pose("map", "odom")
        except (tf2_ros.TransformException, ValueError):
            return "stale or missing transform"
        if self.last_map_odom and (
            math.dist(map_odom[:2], self.last_map_odom[:2]) > 0.3
            or abs(core.angle_difference(map_odom[2], self.last_map_odom[2])) > 0.3
        ):
            self.fault = "localization jump; restart exploration"
        self.last_map_odom = map_odom
        measured = self.samples["odom"].value
        if self.last_pose:
            distance = math.dist(odom[:2], self.last_pose[:2])
            if distance > 0.2:
                self.fault = "odometry jump; restart exploration"
            if measured.linear.x < -0.01:
                self.reverse_distance += distance
        self.last_pose = odom
        if measured.linear.x >= 0 and core.footprint_clear(
            self.samples["map"].value, mapped, self.footprint
        ):
            self.corridor.record(odom, self.footprint, now)
        if self.fault:
            return self.fault
        if self.reverse_distance >= self.reverse_budget:
            return "reverse distance budget spent"
        if self.started and now - self.started >= self.max_duration:
            return "mission time limit"
        if (
            not self.lease
            or not self.lease.fresh(ros_now, now, 0.5)
            or not self.lease.value["enabled"]
        ):
            return "motion not authorized"
        command = self.samples.get("command")
        if not command or not command.fresh(ros_now, now, 0.25):
            return "stale or missing command"
        twist = command.value
        if not all(math.isfinite(v) for v in (twist.linear.x, twist.linear.y, twist.angular.z)):
            return "non-finite command"
        if abs(twist.linear.y) > 1e-6:
            return "lateral velocity requested"
        v = max(-self.reverse_speed, min(self.max_speed, twist.linear.x))
        if self.lease.value["mode"] == "retreat":
            if now - self.retreat_started > 6.0:
                return "retreat time limit"
            if self.reverse_distance - self.retreat_start_distance >= 0.25:
                return "retreat distance limit"
            if v > 0.001:
                return "forward command during retreat"
            v = max(-0.10, v)
        elif v < -0.001:
            return "reverse requires retreat authorization"
        # Preserve curvature when applying the speed limit.
        w = twist.angular.z * v / twist.linear.x if abs(twist.linear.x) > 1e-6 else 0.0
        w = max(-abs(v) / self.radius, min(abs(v) / self.radius, w))
        self.command = (v, w)
        return motion_error(
            self.samples["map"].value,
            self.samples["local"].value,
            mapped,
            odom,
            self.footprint,
            self.lease.value["origin"],
            self.lease.value["perimeter"],
            v,
            w,
            measured.linear.x,
            measured.angular.z,
            self.corridor,
            now,
            reaction_time=self.reaction,
            deceleration=self.deceleration,
        )

    def tick(self):
        now = time.monotonic()
        ros_now = self.get_clock().now().nanoseconds * 1e-9
        try:
            error = self.evaluate(now, ros_now)
        except Exception as exc:  # noqa: BLE001 - Any malformed input fails closed.
            error = f"guard error: {exc!r}"
        output = TwistStamped()
        output.header.stamp = self.get_clock().now().to_msg()
        output.header.frame_id = "rear_axle"
        if error is None:
            output.twist.linear.x, output.twist.angular.z = self.command
        self.output.publish(output)
        health = self.health(now, ros_now)
        self.status.publish(
            String(
                data=json.dumps(
                    {
                        "stamp": ros_now,
                        "ready": health is None,
                        "reason": error,
                        "fault": self.fault,
                        "reverse_distance": self.reverse_distance,
                        "speed": self.samples["odom"].value.linear.x
                        if "odom" in self.samples
                        else None,
                    }
                )
            )
        )


def main():
    rclpy.init()
    node = MotionGuard()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
