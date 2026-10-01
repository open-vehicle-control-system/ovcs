"""Select camera viewpoints; Nav2 plans and follows complete Ackermann routes."""

import json
import math
import signal
import time
import uuid
from itertools import pairwise

import forward_explore_core as core
import rclpy
import rclpy.signals
import tf2_ros
from action_session import ActionSession
from geometry_msgs.msg import PoseStamped
from nav2_msgs.action import ComputePathToPose, FollowPath, NavigateToPose
from nav_msgs.msg import OccupancyGrid, Path
from rclpy.action import ActionClient
from rclpy.clock import Clock, ClockType
from rclpy.node import Node
from rclpy.time import Time
from recovery import DrivenPath
from ros_support import LATCHED, Sample, pose_of, seconds, to_grid, yaw_of
from std_msgs.msg import Bool, String
from visualization_msgs.msg import Marker, MarkerArray


class ForwardExplore(Node):
    def __init__(self):
        super().__init__("forward_explore")
        p = self.declare_parameter
        self.footprint = core.Footprint(
            p("front", 0.462).value, p("rear", 0.138).value, p("half_width", 0.19).value
        )
        self.left_fov = math.radians(p("camera_left_fov_deg", 13.0).value)
        self.right_fov = math.radians(p("camera_right_fov_deg", 22.0).value)
        self.camera_offset = (p("camera_forward", 0.204).value, p("camera_left", 0.045).value)
        self.camera_near = p("camera_near", 0.55).value
        self.camera_far = p("camera_far", 3.0).value
        self.min_gain = p("min_gain_area", 0.04).value
        self.perimeter = p("perimeter", 4.0).value
        self.max_duration = p("max_duration", 600.0).value
        self.goal_timeout = p("goal_timeout", 60.0).value
        self.max_no_progress = p("max_no_progress", 6).value
        self.retreat_distance = p("retreat_distance", 0.20).value
        self.dry_run = p("dry_run", False).value
        self.tf = tf2_ros.Buffer()
        self.listener = tf2_ros.TransformListener(self.tf, self)
        self.create_subscription(OccupancyGrid, "/rtabmap/map", self.on_map, LATCHED)
        self.create_subscription(Path, "/plan", self.on_plan, 10)
        self.create_subscription(Bool, "/forward_explore/resume", self.on_resume, 10)
        self.create_subscription(String, "/motion_guard/status", self.on_guard, 10)
        self.lease = self.create_publisher(String, "/forward_explore/lease", 1)
        self.markers = self.create_publisher(MarkerArray, "/forward_explore/candidates", 10)
        self.navigate = ActionClient(self, NavigateToPose, "navigate_to_pose")
        self.planner = ActionClient(self, ComputePathToPose, "compute_path_to_pose")
        self.follow = ActionClient(self, FollowPath, "follow_path")
        self.planning = None
        self.proposals = []
        self.planned = []
        self.proposal = None
        self.map = None
        self.guard = None
        self.session = None
        self.session_kind = "forward"
        self.driven = DrivenPath()
        self.retreat_count = 0
        self.retreat_used = False
        self.retreat_request = None
        self.path = []
        self.path_valid = False
        self.path_stamp = 0.0
        self.goal_stamp = 0.0
        self.goal = None
        self.origin = None
        self.started = time.monotonic()
        self.mission = str(uuid.uuid4())
        self.avoid = []
        self.no_progress = 0
        self.area_before = None
        self.settle_until = 0.0
        self.blocked_since = None
        self.next_choice = 0.0
        self.paused = False
        self.finishing = False
        self.state = "choose"
        self.timer = self.create_timer(
            0.1, self.tick, clock=Clock(clock_type=ClockType.STEADY_TIME)
        )
        self.get_logger().info(
            "Viewpoint exploration started" + (" (dry run)." if self.dry_run else ".")
        )

    def ros_now(self):
        return self.get_clock().now().nanoseconds * 1e-9

    def on_map(self, msg):
        try:
            if msg.header.frame_id != "map":
                raise ValueError("map must be in map frame")
            grid = to_grid(msg)
            if self.map and (
                grid.known_area < self.map.value.known_area * 0.7
                or seconds(msg.header.stamp) < self.map.stamp - 0.1
            ):
                self.finish("map reset")
            self.map = Sample(grid, seconds(msg.header.stamp), time.monotonic())
            self.validate_path()
            if self.session and self.path and not self.path_valid:
                self.cancel("map changed: route is no longer clear")
        except (ValueError, TypeError) as error:
            self.map = None
            self.finish(f"invalid map: {error}")

    def on_plan(self, msg):
        if (
            self.session is None
            or self.session_kind != "forward"
            or self.goal is None
            or msg.header.frame_id != "map"
            or seconds(msg.header.stamp) < self.goal_stamp
            or not msg.poses
        ):
            return
        poses = [pose_of(p.pose) for p in msg.poses]
        if not self.at_goal(poses[-1]):
            self.path_valid = False
            self.cancel("unexpected navigation plan")
            return
        self.path, self.path_stamp = poses, seconds(msg.header.stamp)
        self.validate_path()
        if not self.path_valid:
            self.cancel("plan leaves mapped free space or the perimeter")

    def validate_path(self):
        self.path_valid = bool(
            self.map
            and self.path
            and self.origin
            and core.path_clear(
                self.path, self.map.value, self.footprint, self.origin, self.perimeter
            )
        )

    def on_guard(self, msg):
        try:
            data = json.loads(msg.data)
            self.guard = Sample(data, data["stamp"], time.monotonic())
        except (ValueError, TypeError, KeyError):
            self.guard = None

    def on_resume(self, msg):
        if not msg.data:
            self.paused = True
            self.cancel("paused")
        elif self.paused and not self.finishing:
            # Never overlap a resumed mission with a pending cancellation.
            if (self.session and not self.session.done) or (
                self.planning and not self.planning.done
            ):
                self.get_logger().warning(
                    "Waiting for the previous action to terminate before resuming."
                )
                return
            self.paused = False
            self.origin = None
            self.started = time.monotonic()
            self.mission = str(uuid.uuid4())
            self.avoid = []
            self.no_progress = 0
            self.driven = DrivenPath()
            self.retreat_count = 0
            self.retreat_used = False
            self.retreat_request = None
            self.path = []
            self.path_valid = False
            self.get_logger().info("Exploration resumed with a new mission boundary.")

    def pose(self, frame="map", child="rear_axle"):
        try:
            transform = self.tf.lookup_transform(frame, child, Time())
            if not -0.1 <= self.ros_now() - seconds(transform.header.stamp) <= 0.5:
                return None
            t = transform.transform
            return t.translation.x, t.translation.y, yaw_of(t.rotation)
        except tf2_ros.TransformException:
            return None

    def publish_lease(self, enabled=False):
        if self.origin is None:
            return
        self.lease.publish(
            String(
                data=json.dumps(
                    {
                        "mission": self.mission,
                        "stamp": self.ros_now(),
                        "origin": self.origin,
                        "perimeter": self.perimeter,
                        "enabled": enabled and not self.dry_run,
                        "mode": self.session_kind,
                        "retreat": self.retreat_count,
                    }
                )
            )
        )

    def tick(self):
        try:
            self.step()
        except Exception as error:  # noqa: BLE001 - Revocation must survive a callback failure.
            self.get_logger().error(f"Exploration failed: {error!r}")
            self.finish("error")

    def step(self):
        now = time.monotonic()
        self.poll_planning(now)
        if self.state == "done":
            return
        if self.session:
            self.session.poll(now)
            if self.session.unsafe:
                self.finish("action did not acknowledge cancellation; motion revoked")
                self.state = "done"
                return
            if self.session.done:
                if not self.paused and not self.finishing:
                    pose = self.pose()
                    success = self.session.status == 4 and pose is not None and self.at_goal(pose)
                    if self.session_kind == "retreat":
                        self.area_before = None
                        self.next_choice = now + 0.5
                        if success:
                            self.get_logger().info(
                                "Short retreat completed; choosing another route."
                            )
                        else:
                            self.finish("short retreat failed; no repeated reverse attempts")
                    elif success:
                        self.avoid.append((self.goal, now + 60.0))
                        self.settle_until = now + 1.5
                        self.get_logger().info("Viewpoint reached; waiting for the map update.")
                    else:
                        self.avoid.append((self.goal, now + 60.0))
                        self.no_progress += 1
                        self.area_before = None
                        self.get_logger().warning(
                            f"Viewpoint failed: {self.session.reason or self.session.status}"
                        )
                        self.request_retreat("viewpoint failed", now)
                self.session = None
                self.goal = None
                self.path = []
                self.path_valid = False
                self.publish_lease(False)
        if self.finishing:
            self.publish_lease(False)
            if self.session is None and self.planning is None:
                self.state = "done"
            return
        if self.paused:
            self.publish_lease(False)
            return
        if now - self.started >= self.max_duration:
            return self.finish("time limit reached")
        healthy = (
            self.map
            and self.map.fresh(self.ros_now(), now, 3.0)
            and self.guard
            and self.guard.fresh(self.ros_now(), now, 0.5)
            and self.guard.value["ready"]
            and not self.guard.value.get("fault")
        )
        if self.session:
            if not healthy or self.guard.value.get("fault"):
                return self.finish("sensor, localization or motion guard unavailable")
            enabled = self.session.active and self.path_valid
            if enabled and self.session_kind == "forward":
                odom = self.pose("odom")
                if odom is not None:
                    self.driven.record(odom, now)
            self.publish_lease(enabled)
            reason = self.guard.value.get("reason")
            blocked = enabled and reason not in (
                None,
                "motion not authorized",
                "stale or missing command",
            )
            if blocked:
                self.blocked_since = self.blocked_since or now
                if now - self.blocked_since > 1.0:
                    self.cancel(f"motion guard: {reason}")
            else:
                self.blocked_since = None
            return
        self.publish_lease(False)
        if not healthy or now < self.next_choice or now < self.settle_until:
            return
        if self.planning:
            return
        if self.retreat_request:
            return self.try_retreat(now)
        if self.proposals:
            return self.plan_next(now)
        if self.planned:
            _, gain, goal = max(self.planned)
            self.planned = []
            return self.dispatch(goal, gain, now)
        if self.area_before is not None:
            gained = self.map.value.known_area - self.area_before >= self.min_gain
            self.no_progress = 0 if gained else self.no_progress + 1
            if gained:
                self.retreat_used = False
            self.area_before = None
        if self.no_progress >= self.max_no_progress:
            return self.finish("no mapping progress; bounded retry limit reached")
        self.next_choice = now + 1.0
        self.choose(now)

    def choose(self, now):
        pose = self.pose()
        if pose is None:
            return
        if self.origin is None:
            self.origin = pose[:2]
            self.publish_lease(False)
        if not core.footprint_clear(self.map.value, pose, self.footprint):
            self.get_logger().warning(
                "Waiting for known free space under the complete footprint."
            )
            return
        self.avoid = [(goal, expiry) for goal, expiry in self.avoid if expiry > now]
        scored = []
        for goal in core.viewpoints(
            self.map.value, pose, self.footprint, self.origin, self.perimeter
        ):
            if any(
                math.dist(goal[:2], old[:2]) < 0.4
                and abs(core.angle_difference(goal[2], old[2])) < 0.6
                for old, _ in self.avoid
            ):
                continue
            camera = (*core.to_frame(goal, *self.camera_offset), goal[2])
            gain = core.visible_unknown(
                self.map.value,
                camera,
                self.left_fov,
                self.right_fov,
                self.camera_near,
                self.camera_far,
            )
            if gain >= self.min_gain:
                travel_cost = (
                    1
                    + math.dist(goal[:2], pose[:2])
                    + 2 * abs(core.angle_difference(goal[2], pose[2]))
                )
                scored.append((gain / travel_cost, gain, goal))
        self.publish_markers(scored)
        if not scored:
            return self.request_retreat(
                "no untried safe viewpoint in the perimeter", now, terminal=True
            )
        if self.dry_run:
            _, gain, goal = max(scored)
            self.get_logger().info(f"Dry-run viewpoint: {goal}, potential gain {gain:.2f} m²")
            return
        if not self.planner.server_is_ready() or not self.navigate.server_is_ready():
            return
        self.proposals = []
        for candidate in sorted(scored, reverse=True):
            goal = candidate[2]
            if any(
                math.dist(goal[:2], old[2][:2]) < 0.6
                and abs(core.angle_difference(goal[2], old[2][2])) < 0.7
                for old in self.proposals
            ):
                continue
            self.proposals.append(candidate)
            if len(self.proposals) == 16:
                break
        self.plan_next(now)

    @staticmethod
    def goal_pose(goal, stamp):
        pose = PoseStamped()
        pose.header.frame_id, pose.header.stamp = "map", stamp
        pose.pose.position.x, pose.pose.position.y = goal[:2]
        pose.pose.orientation.z, pose.pose.orientation.w = (
            math.sin(goal[2] / 2),
            math.cos(goal[2] / 2),
        )
        return pose

    def plan_next(self, now):
        self.proposal = self.proposals.pop(0)
        request = ComputePathToPose.Goal()
        request.goal = self.goal_pose(self.proposal[2], self.get_clock().now().to_msg())
        request.planner_id = "GridBased"
        self.planning = ActionSession(self.planner, request, now, execution_timeout=3.0)

    def poll_planning(self, now):
        if self.planning is None:
            return
        self.planning.poll(now)
        if self.planning.unsafe:
            self.finish("planner did not terminate")
            self.state = "done"
            return
        if not self.planning.done:
            return
        _, gain, goal = self.proposal
        accepted = False
        if self.planning.status == 4 and not self.paused and not self.finishing and self.map:
            path = self.planning.result.result().result.path
            poses = [pose_of(p.pose) for p in path.poses]
            if path.header.frame_id == "map" and core.path_clear(
                poses, self.map.value, self.footprint, self.origin, self.perimeter
            ):
                length = sum(math.dist(a[:2], b[:2]) for a, b in pairwise(poses))
                turning = sum(abs(core.angle_difference(b[2], a[2])) for a, b in pairwise(poses))
                self.planned.append((gain / (1 + length + 0.5 * turning), gain, goal))
                accepted = True
        if not accepted:
            self.avoid.append((goal, now + 30.0))
        self.planning = None
        if not self.proposals and not self.planned:
            self.no_progress += 1
            self.request_retreat("no feasible candidate route", now)

    def dispatch(self, goal, gain, now):
        self.session_kind = "forward"
        self.get_logger().info(
            f"Viewpoint ({goal[0]:.2f}, {goal[1]:.2f}, {math.degrees(goal[2]):.0f} deg), potential gain {gain:.2f} m²"
        )
        message = NavigateToPose.Goal()
        message.pose = self.goal_pose(goal, self.get_clock().now().to_msg())
        self.goal, self.goal_stamp = goal, seconds(message.pose.header.stamp)
        self.path, self.path_valid = [], False
        self.area_before = self.map.value.known_area
        self.session = ActionSession(
            self.navigate, message, now, execution_timeout=self.goal_timeout
        )

    def at_goal(self, pose):
        return (
            self.goal is not None
            and math.dist(pose[:2], self.goal[:2])
            <= (0.04 if self.session_kind == "retreat" else 0.15)
            and abs(core.angle_difference(pose[2], self.goal[2])) <= 0.25
        )

    def cancel(self, reason):
        self.publish_lease(False)
        self.retreat_request = None
        self.proposals = []
        self.planned = []
        if self.session:
            self.session.cancel(time.monotonic(), reason)
        if self.planning:
            self.planning.cancel(time.monotonic(), reason)

    def request_retreat(self, reason, now, terminal=False):
        if self.paused or self.finishing:
            return
        if self.dry_run or self.retreat_used or self.retreat_count >= 3:
            if terminal:
                self.finish(reason)
            return
        self.retreat_request = (reason, now, terminal)

    def try_retreat(self, now):
        reason, requested, terminal = self.retreat_request
        # The old action is terminal before this method runs; also wait for physical standstill.
        if abs(self.guard.value.get("speed", math.inf)) > 0.01 and now - requested < 1.0:
            return
        odom, map_odom = self.pose("odom"), self.pose("map", "odom")
        poses = self.driven.retreat(odom, now, self.retreat_distance) if odom else []
        mapped = (
            [(*core.to_frame(map_odom, p[0], p[1]), p[2] + map_odom[2]) for p in poses]
            if map_odom
            else []
        )
        ready = (
            0 < self.retreat_distance <= 0.20
            and abs(self.guard.value.get("speed", math.inf)) <= 0.01
            and self.follow.server_is_ready()
            and core.path_clear(
                mapped, self.map.value, self.footprint, self.origin, self.perimeter
            )
        )
        self.retreat_request = None
        if not ready:
            if terminal:
                self.finish(f"{reason}; no recent clear retreat")
            return
        self.proposals, self.planned = [], []
        self.retreat_used = True
        self.retreat_count += 1
        self.session_kind = "retreat"
        self.goal, self.path = mapped[-1], mapped
        self.path_valid = True
        self.blocked_since = None
        self.area_before = None
        stamp = self.get_clock().now().to_msg()
        request = FollowPath.Goal()
        request.path.header.frame_id, request.path.header.stamp = "map", stamp
        request.path.poses = [self.goal_pose(p, stamp) for p in mapped]
        request.controller_id = "Retreat"
        request.goal_checker_id = "retreat_goal_checker"
        request.progress_checker_id = "retreat_progress_checker"
        self.session = ActionSession(self.follow, request, now, execution_timeout=6.0)
        self.get_logger().info(
            f"Short retreat {self.retreat_count}: retracing {self.retreat_distance:.2f} m ({reason})."
        )

    def finish(self, reason):
        if not self.finishing:
            self.get_logger().info(f"Exploration finished: {reason}.")
        self.finishing = True
        self.cancel(reason)

    def publish_markers(self, scored):
        array = MarkerArray()
        array.markers.append(Marker(action=Marker.DELETEALL))
        for index, (_, gain, pose) in enumerate(scored):
            marker = Marker()
            marker.header.frame_id = "map"
            marker.ns, marker.id, marker.type, marker.action = (
                "viewpoints",
                index,
                Marker.ARROW,
                Marker.ADD,
            )
            marker.pose.position.x, marker.pose.position.y = pose[:2]
            marker.pose.orientation.z, marker.pose.orientation.w = (
                math.sin(pose[2] / 2),
                math.cos(pose[2] / 2),
            )
            marker.scale.x, marker.scale.y, marker.scale.z = 0.2, 0.03, 0.03
            marker.color.r, marker.color.g, marker.color.b, marker.color.a = (
                0.2,
                min(gain, 1.0),
                0.3,
                0.9,
            )
            array.markers.append(marker)
        self.markers.publish(array)


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def main():
    rclpy.init(signal_handler_options=rclpy.signals.SignalHandlerOptions.NO)
    node = ForwardExplore()
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        while rclpy.ok() and node.state != "done":
            rclpy.spin_once(node, timeout_sec=0.1)
    except KeyboardInterrupt:
        node.finish("interrupted")
        deadline = time.monotonic() + 3.5
        while rclpy.ok() and node.state != "done" and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
    finally:
        node.publish_lease(False)
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
