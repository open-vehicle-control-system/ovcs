"""Forward-cone exploration: drive towards the unknown the camera can reach.

Every cycle, with no goal running, it scores goals in a cone ahead of the
car (see forward_explore_core) against RTAB-Map's grid and the local
costmap, and sends the arc to the best to Nav2's controller. When nothing worth seeing is left
ahead it reverses along an arc, steering to the clearer side, and then
takes the goal turned furthest the same way: a three-point turn. It stops at a time limit, when the reverse budget is spent,
when nothing is reachable, or on `forward_explore/resume` false. Goals
beyond a perimeter around the start are never sent.

It starts driving as soon as it runs: launch it on demand, never at boot.
"""

import math
import pathlib
import signal
import sys
import time

import numpy as np
import rclpy
import rclpy.signals
import tf2_ros
from geometry_msgs.msg import PoseStamped
from nav2_msgs.action import FollowPath
from nav_msgs.msg import OccupancyGrid, Path
from rclpy.action import ActionClient
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from rclpy.time import Time
from std_msgs.msg import Bool
from visualization_msgs.msg import Marker, MarkerArray

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import forward_explore_core as core


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def to_grid(msg):
    data = np.array(msg.data, dtype=np.int16).reshape(msg.info.height, msg.info.width)
    origin = msg.info.origin.position
    return core.Grid(data, msg.info.resolution, origin.x, origin.y)


class ForwardExplore(Node):
    def __init__(self):
        super().__init__("forward_explore")
        p = self.declare_parameter
        self.cone = math.radians(p("cone_half_angle_deg", 60.0).value)
        self.angle_step = math.radians(p("angle_step_deg", 10.0).value)
        self.distances = list(p("distances", [1.0, 1.5, 2.0]).value)
        self.min_radius = p("min_turn_radius", 0.7).value
        self.footprint = (p("footprint_half_length", 0.30).value, p("footprint_half_width", 0.19).value)
        self.half_fov = math.radians(p("camera_half_fov_deg", 18.0).value)
        self.camera_near = p("camera_near", 0.55).value
        self.camera_far = p("camera_far", 3.0).value
        self.min_gain = p("min_gain", 15).value
        self.avoid_radius = p("avoid_radius", 0.6).value
        self.avoid_penalty = p("avoid_penalty", 30).value
        self.perimeter = p("perimeter", 4.0).value
        self.max_duration = p("max_duration", 600.0).value
        self.goal_timeout = p("goal_timeout", 40.0).value
        # Exploring needs the view, not the exact spot: a goal counts as
        # reached this close, or once behind the car, which cannot drive
        # back to it.
        self.reach_radius = p("reach_radius", 0.4).value
        self.reverse_distance = p("reverse_distance", 0.5).value
        self.reverse_budget = p("reverse_budget", 3.0).value
        # Drive only through space the map has seen free, past the camera's
        # blind first metres.
        self.seen_free_skip = p("seen_free_skip", 0.6).value
        self.map_topic = p("map_topic", "/rtabmap/map").value
        self.costmap_topic = p("costmap_topic", "/local_costmap/costmap").value
        # Choose and log, but send nothing to Nav2.
        self.dry_run = p("dry_run", False).value

        self.map = None
        self.costmap = None
        self.tf = tf2_ros.Buffer()
        self.tf_listener = tf2_ros.TransformListener(self.tf, self)
        latched = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL, reliability=ReliabilityPolicy.RELIABLE)
        self.create_subscription(OccupancyGrid, self.map_topic, self.on_map, latched)
        self.create_subscription(OccupancyGrid, self.costmap_topic, self.on_costmap, latched)
        self.create_subscription(Bool, "forward_explore/resume", self.on_resume, 10)
        self.markers = self.create_publisher(MarkerArray, "forward_explore/candidates", 10)
        # The controller follows the arc itself: the global planner draws
        # straight lines this car cannot turn onto.
        self.navigate = ActionClient(self, FollowPath, "follow_path")

        self.started = time.monotonic()
        self.start_map = None
        self.visited = []
        self.failed_goals = []
        self.reversed = 0.0
        # Sign of the turn the last reverse arc started, 0 when none.
        self.turn_sign = 0
        self.paused = False
        self.state = "choose"
        self.goal = None
        self.goal_odom = None
        self.goal_handle_future = None
        self.result_future = None
        self.sent_at = None
        self.timer = self.create_timer(1.0, self.tick)
        self.get_logger().info("Forward exploration started" + (" (dry run)." if self.dry_run else "."))

    def on_map(self, msg):
        self.map = to_grid(msg)

    def on_costmap(self, msg):
        self.costmap = to_grid(msg)

    def on_resume(self, msg):
        if msg.data and self.paused:
            self.paused = False
            self.state = "choose"
            self.get_logger().info("Exploration resumed.")
        elif not msg.data and not self.paused:
            self.paused = True
            self.cancel()
            self.get_logger().info("Exploration paused.")

    def pose(self, frame):
        try:
            t = self.tf.lookup_transform(frame, "base_link", Time())
        except tf2_ros.TransformException:
            return None
        return (t.transform.translation.x, t.transform.translation.y, yaw_of(t.transform.rotation))

    def tick(self):
        try:
            self.step()
        except Exception as error:  # noqa: BLE001 - any failure must stop the car
            self.get_logger().error(f"Exploration failed: {error!r}")
            self.finish("error")

    def step(self):
        if self.paused or self.state == "done":
            return
        if time.monotonic() - self.started > self.max_duration:
            return self.finish("time limit reached")
        if self.state in ("driving", "reversing"):
            return self.follow()
        if self.state == "choose":
            self.choose()

    def choose(self):
        odom, in_map = self.pose("odom"), self.pose("map")
        if self.map is None or self.costmap is None or odom is None or in_map is None:
            self.get_logger().info("Waiting for the map, the costmap and the transforms.")
            return
        if self.start_map is None:
            self.start_map = in_map[:2]
        scored = []
        for c in core.candidates(self.cone, self.distances, self.angle_step):
            if not core.reachable(c, self.costmap, odom, self.min_radius, self.footprint, self.costmap.resolution):
                continue
            if not core.seen_free(self.map, in_map, c, self.seen_free_skip, self.map.resolution):
                continue
            goal_map = core.to_frame(in_map, c.forward, c.lateral)
            if math.dist(goal_map, self.start_map) > self.perimeter:
                continue
            if core.near_any(goal_map, self.failed_goals, self.avoid_radius):
                continue
            view = (*goal_map, in_map[2] + core.end_heading(c.forward, c.lateral))
            gain = core.visible_unknown(self.map, view, self.half_fov, self.camera_near, self.camera_far, self.map.resolution)
            value = core.score(goal_map, gain, self.visited, self.avoid_radius, self.avoid_penalty)
            scored.append((value, gain, c, goal_map))
        self.publish_markers(odom, scored)
        if not scored:
            return self.turn_or_finish("no reachable goal ahead", odom, in_map)
        if self.turn_sign:
            sign = self.turn_sign
            best = max(scored, key=lambda s: sign * math.atan2(s[2].lateral, s[2].forward) + 0.01 * s[0])
            self.turn_sign = 0
        else:
            best = max(scored, key=lambda s: s[0])
            if best[1] < self.min_gain or best[0] <= 0:
                return self.turn_or_finish(f"nothing left to see ahead (best gain {best[1]})", odom, in_map)
        _, gain, c, goal_map = best
        self.send(odom, c, gain, goal_map)

    def turn_or_finish(self, reason, odom, in_map):
        if self.reversed + self.reverse_distance > self.reverse_budget + 1e-9:
            return self.finish(reason + ", reverse budget spent")
        sides = []
        for radius in (self.min_radius, -self.min_radius):
            poses = core.reverse_arc_poses(self.reverse_distance, radius, 0.1)
            if not core.poses_clear(poses, self.costmap, odom, self.footprint, self.costmap.resolution):
                continue
            f, lat, heading = poses[-1]
            view = (*core.to_frame(in_map, f, lat), in_map[2] + heading)
            gain = core.visible_unknown(self.map, view, self.half_fov, self.camera_near, self.camera_far, self.map.resolution)
            sides.append((gain, radius))
        if not sides:
            return self.finish(reason + ", no room to reverse")
        gain, radius = max(sides)
        side = "right" if radius > 0 else "left"
        self.get_logger().info(f"{reason}: reversing {self.reverse_distance:.2f} m to turn {side} (to see {gain} unknown cells).")
        path = self.path(odom, core.reverse_arc_poses(self.reverse_distance, radius, 0.01))
        self.goal_odom = None
        if not self.dry_run:
            self.reversed += self.reverse_distance
            self.turn_sign = -1 if radius > 0 else 1
        self.dispatch(self.navigate, self.follow_goal(path, "ReverseArc"), "reversing", None)

    def path(self, odom, poses):
        path = Path()
        path.header.frame_id = "odom"
        path.header.stamp = self.get_clock().now().to_msg()
        for f, lat, heading in poses:
            pose = PoseStamped()
            pose.header = path.header
            pose.pose.position.x, pose.pose.position.y = core.to_frame(odom, f, lat)
            yaw = odom[2] + heading
            pose.pose.orientation.z, pose.pose.orientation.w = math.sin(yaw / 2), math.cos(yaw / 2)
            path.poses.append(pose)
        return path

    @staticmethod
    def follow_goal(path, controller):
        goal = FollowPath.Goal()
        goal.path = path
        goal.controller_id = controller
        goal.goal_checker_id = "goal_checker"
        return goal

    def send(self, odom, c, gain, goal_map):
        # MPPI's PathAlignCritic ignores a path shorter than its
        # offset_from_furthest (20 poses): at 5 cm a step this short is
        # chased as a point.
        path = self.path(odom, core.arc_poses(c.forward, c.lateral, 0.01))
        x, y = core.to_frame(odom, c.forward, c.lateral)
        self.goal_odom = (x, y)
        distance = math.hypot(c.forward, c.lateral)
        angle = math.degrees(math.atan2(c.lateral, c.forward))
        self.get_logger().info(
            f"Goal {distance:.1f} m ahead, {angle:+.0f} deg, to see {gain} unknown cells"
            f" (odom {x:.2f}, {y:.2f})."
        )
        self.dispatch(self.navigate, self.follow_goal(path, "FollowPath"), "driving", goal_map)

    def dispatch(self, client, goal, state, goal_map):
        if self.dry_run:
            self.get_logger().info("Dry run: not sent.")
            self.state = "choose"
            return
        if not client.wait_for_server(timeout_sec=2.0):
            self.get_logger().warning("Nav2 action server not available; retrying.")
            self.state = "choose"
            return
        self.goal = goal_map
        self.goal_handle_future = client.send_goal_async(goal)
        self.result_future = None
        self.sent_at = time.monotonic()
        self.state = state

    def follow(self):
        if self.result_future is None:
            if not self.goal_handle_future.done():
                return
            handle = self.goal_handle_future.result()
            if not handle.accepted:
                self.get_logger().warning("Goal rejected.")
                return self.failed()
            self.result_future = handle.get_result_async()
        if not self.result_future.done():
            if self.state == "driving" and self.close_enough():
                self.cancel()
                self.visited.append(self.goal)
                self.state = "choose"
                return
            if time.monotonic() - self.sent_at > self.goal_timeout:
                self.get_logger().warning(f"Goal timed out after {self.goal_timeout:.0f} s; cancelling.")
                self.cancel()
                return self.failed()
            return
        status = self.result_future.result().status
        if status == 4:  # GoalStatus.STATUS_SUCCEEDED
            if self.state == "driving":
                self.get_logger().info("Goal reached.")
                self.visited.append(self.goal)
            else:
                self.get_logger().info("Reversed.")
            self.state = "choose"
        else:
            what = "Goal" if self.state == "driving" else "Reverse arc"
            self.get_logger().warning(f"{what} ended with status {status}.")
            self.failed()

    def close_enough(self):
        odom = self.pose("odom")
        if odom is None or self.goal_odom is None:
            return False
        dx, dy = self.goal_odom[0] - odom[0], self.goal_odom[1] - odom[1]
        distance = math.hypot(dx, dy)
        ahead = math.cos(odom[2]) * dx + math.sin(odom[2]) * dy
        if distance < self.reach_radius:
            self.get_logger().info(f"Goal reached, {distance:.2f} m from it.")
            return True
        if ahead < 0.0:
            self.get_logger().info(f"Goal passed, {distance:.2f} m behind; moving on.")
            return True
        return False

    def failed(self):
        if self.goal is not None:
            self.failed_goals.append(self.goal)
        self.state = "choose"

    def cancel(self):
        if self.goal_handle_future is not None and self.goal_handle_future.done():
            handle = self.goal_handle_future.result()
            if handle.accepted:
                handle.cancel_goal_async()

    def finish(self, reason):
        self.cancel()
        self.state = "done"
        self.timer.cancel()
        self.get_logger().info(f"Exploration finished: {reason}.")

    def publish_markers(self, odom, scored):
        array = MarkerArray()
        clear = Marker()
        clear.action = Marker.DELETEALL
        array.markers.append(clear)
        top = max((s[1] for s in scored), default=1) or 1
        for k, (_, gain, c, _) in enumerate(scored):
            m = Marker()
            m.header.frame_id = "odom"
            m.ns, m.id, m.type, m.action = "candidates", k, Marker.SPHERE, Marker.ADD
            m.pose.position.x, m.pose.position.y = core.to_frame(odom, c.forward, c.lateral)
            m.pose.orientation.w = 1.0
            m.scale.x = m.scale.y = m.scale.z = 0.08
            m.color.r, m.color.g, m.color.b, m.color.a = 1.0 - gain / top, gain / top, 0.2, 0.9
            array.markers.append(m)
        self.markers.publish(array)


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def main():
    # rclpy's own handler shuts the context down first, and the cancel
    # then cannot be sent: stop on SIGINT and SIGTERM here instead.
    rclpy.init(signal_handler_options=rclpy.signals.SignalHandlerOptions.NO)
    node = ForwardExplore()
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        while rclpy.ok() and node.state != "done":
            rclpy.spin_once(node, timeout_sec=0.2)
    except KeyboardInterrupt:
        node.cancel()
        # Let the cancel request go out before the node is destroyed.
        rclpy.spin_once(node, timeout_sec=0.5)
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
