"""Run inside the ROS image: real actions and node-level fault injection."""

import json
import math
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    import rclpy
except ImportError:
    rclpy = None

if rclpy:
    from action_session import ActionSession
    from forward_explore_node import ForwardExplore
    from geometry_msgs.msg import TransformStamped, TwistStamped
    from motion_guard import MotionGuard
    from nav2_msgs.action import NavigateToPose
    from nav_msgs.msg import OccupancyGrid, Odometry
    from nav_msgs.msg import Path as RosPath
    from rclpy.action import ActionClient, ActionServer, CancelResponse
    from rclpy.callback_groups import ReentrantCallbackGroup
    from rclpy.executors import MultiThreadedExecutor
    from rclpy.node import Node
    from sensor_msgs.msg import PointCloud2
    from std_msgs.msg import Bool, String


@unittest.skipUnless(rclpy, "ROS node tests run in the Nav2 image")
class NodeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rclpy.init()

    @classmethod
    def tearDownClass(cls):
        rclpy.shutdown()

    def setUp(self):
        self.guard = MotionGuard()
        self.guard.timer.cancel()
        self.explorer = ForwardExplore()
        self.explorer.timer.cancel()

    def tearDown(self):
        self.explorer.destroy_node()
        self.guard.destroy_node()

    def stamp(self):
        return self.guard.get_clock().now().to_msg()

    def transform(self, parent, child, x=0):
        msg = TransformStamped()
        msg.header.frame_id, msg.child_frame_id = parent, child
        msg.header.stamp = getattr(self, "input_stamp", self.stamp())
        msg.transform.translation.x = float(x)
        msg.transform.rotation.w = 1.0
        self.guard.tf.set_transform(msg, "test")
        self.explorer.tf.set_transform(msg, "test")

    def inputs(self):
        now = self.stamp()
        self.input_stamp = now
        self.guard.on_map_session(
            String(data=json.dumps({"id": "map1", "stamp": now.sec + now.nanosec * 1e-9}))
        )
        for frame, callback in (("map", self.guard.on_map), ("odom", self.guard.on_local)):
            msg = OccupancyGrid()
            msg.header.stamp, msg.header.frame_id = now, frame
            msg.info.resolution, msg.info.width, msg.info.height = 0.05, 160, 160
            msg.info.origin.position.x = msg.info.origin.position.y = -4.0
            msg.info.origin.orientation.w = 1.0
            msg.data = [0] * (160 * 160)
            callback(msg)
            if frame == "map":
                self.explorer.on_map(msg)
        odom = Odometry()
        odom.header.stamp, odom.header.frame_id, odom.child_frame_id = now, "odom", "base_link"
        self.guard.on_odom(odom)
        cloud = PointCloud2()
        cloud.header.stamp, cloud.header.frame_id = now, "stereo_left"
        cloud.width = cloud.height = 1
        cloud.data = [1] * 12
        self.guard.on_cloud(cloud)
        self.transform("map", "odom")
        self.transform("odom", "rear_axle")
        command = TwistStamped()
        command.header.stamp = now
        command.twist.linear.x, command.twist.angular.z = 0.2, 0.1
        self.guard.on_command(command)
        ros_now = self.guard.get_clock().now().nanoseconds * 1e-9
        self.guard.on_lease(
            String(
                data=json.dumps(
                    {
                        "mission": "test",
                        "stamp": ros_now,
                        "origin": [0, 0],
                        "perimeter": 4.0,
                        "enabled": True,
                    }
                )
            )
        )

    def evaluate(self):
        return self.guard.evaluate(
            time.monotonic(), self.guard.get_clock().now().nanoseconds * 1e-9
        )

    def test_healthy_inputs_allow_bounded_curvature_preserving_motion(self):
        self.inputs()
        self.assertIsNone(self.evaluate())
        self.assertAlmostEqual(self.guard.command[0], 0.2)
        self.assertAlmostEqual(self.guard.command[1], 0.1)

    def authorize_retreat(self, identity=1):
        data = dict(self.guard.lease.value)
        data.update(mode="retreat", retreat=identity)
        self.guard.on_lease(String(data=json.dumps(data)))

    def reverse_command(self):
        command = TwistStamped()
        command.header.stamp = self.stamp()
        command.twist.linear.x = -0.12
        self.guard.on_command(command)

    def test_retreat_needs_authorization_and_recent_traversed_clearance(self):
        self.inputs()
        self.reverse_command()
        self.assertEqual(self.evaluate(), "reverse requires retreat authorization")
        self.authorize_retreat()
        self.assertEqual(self.evaluate(), "reverse leaves recently traversed space")
        now = time.monotonic()
        for x in range(-30, 1):
            self.guard.corridor.record((x / 100, 0, 0), self.guard.footprint, now)
        self.assertIsNone(self.evaluate())
        self.assertAlmostEqual(self.guard.command[0], -0.10)
        # A newly occupied rear cell overrides the historical clearance.
        grid = self.guard.samples["local"].value
        i, j = grid.index(-0.22, 0.0)
        grid.data[j, i] = 100
        self.assertEqual(self.evaluate(), "local obstacle or unknown footprint")

    def test_retreat_limits_cannot_be_renewed_by_lease_heartbeats(self):
        self.inputs()
        self.authorize_retreat()
        started = self.guard.retreat_started
        self.guard.reverse_distance = 0.26
        self.authorize_retreat()
        self.assertEqual(self.guard.retreat_started, started)
        self.assertEqual(self.guard.retreat_start_distance, 0.0)
        self.reverse_command()
        self.assertEqual(self.evaluate(), "retreat distance limit")
        self.guard.reverse_distance = 0
        self.guard.retreat_started -= 7
        self.assertEqual(self.evaluate(), "retreat time limit")
        self.authorize_retreat(4)
        self.assertIsNone(self.guard.lease)

    def test_retreat_rejects_forward_commands_and_requires_standstill(self):
        self.inputs()
        self.authorize_retreat()
        self.assertEqual(self.evaluate(), "forward command during retreat")
        self.guard.samples["odom"].value.linear.x = 0.1
        self.authorize_retreat(2)
        self.assertIsNone(self.guard.lease)

    def test_retreat_cannot_repeat_without_new_progress(self):
        self.explorer.retreat_used = True
        self.explorer.request_retreat("blocked", time.monotonic())
        self.assertIsNone(self.explorer.retreat_request)
        self.explorer.retreat_used = False
        self.explorer.retreat_count = 3
        self.explorer.request_retreat("blocked", time.monotonic())
        self.assertIsNone(self.explorer.retreat_request)

    def test_retreat_waits_for_previous_action_to_terminate(self):
        from concurrent.futures import Future
        from types import SimpleNamespace

        self.inputs()
        self.explorer.on_guard(
            String(
                data=json.dumps(
                    {
                        "stamp": self.guard.get_clock().now().nanoseconds * 1e-9,
                        "ready": True,
                        "fault": None,
                        "reason": None,
                        "speed": 0.0,
                    }
                )
            )
        )
        acceptance = Future()
        self.explorer.session = ActionSession(
            SimpleNamespace(send_goal_async=lambda _: acceptance), object(), time.monotonic()
        )
        self.explorer.cancel("blocked")
        self.explorer.request_retreat("blocked", time.monotonic())
        self.explorer.step()
        self.assertEqual(self.explorer.retreat_count, 0)
        self.assertIsNotNone(self.explorer.retreat_request)
        self.assertFalse(self.explorer.session.active)

    def test_each_stale_sensor_independently_stops_motion(self):
        for key in ("map", "local", "cloud", "odom", "command", "mapper"):
            with self.subTest(key=key):
                self.inputs()
                self.guard.samples[key].stamp -= 10
                self.assertIn(key, self.evaluate())

    def test_replayed_cloud_does_not_refresh_receipt_time(self):
        self.inputs()
        sample = self.guard.samples["cloud"]
        sample.received -= 1.0
        cloud = PointCloud2()
        cloud.header.stamp = self.input_stamp
        cloud.width = cloud.height = 1
        cloud.data = [1] * 12
        self.guard.on_cloud(cloud)
        self.assertEqual(self.evaluate(), "stale or missing cloud")

    def test_pause_also_cancels_pending_route_preflight(self):
        from concurrent.futures import Future
        from types import SimpleNamespace

        acceptance = Future()
        self.explorer.planning = ActionSession(
            SimpleNamespace(send_goal_async=lambda _: acceptance), object(), time.monotonic()
        )
        self.explorer.on_resume(Bool(data=False))
        self.assertIsNotNone(self.explorer.planning.cancelled_at)
        self.assertEqual(self.explorer.proposals, [])

    def test_live_inputs_do_not_hide_stale_tf(self):
        self.inputs()
        self.guard.tf.clear()
        self.assertEqual(self.evaluate(), "stale or missing transform")

    def test_missing_expired_and_disabled_authorization_stop_motion(self):
        self.inputs()
        self.guard.lease.received -= 1
        self.assertEqual(self.evaluate(), "motion not authorized")
        self.inputs()
        self.guard.lease.value["enabled"] = False
        self.assertEqual(self.evaluate(), "motion not authorized")
        self.guard.lease = None
        self.assertEqual(self.evaluate(), "motion not authorized")

    def test_map_reset_and_localization_jump_latch_a_fault(self):
        self.inputs()
        self.assertIsNone(self.evaluate())
        self.transform("map", "odom", 0.5)
        self.assertIn("localization jump", self.evaluate())
        self.guard.fault = None
        msg = OccupancyGrid()
        msg.header.stamp, msg.header.frame_id = self.stamp(), "map"
        msg.info.width = msg.info.height = 20
        msg.info.resolution = 0.05
        msg.info.origin.orientation.w = 1.0
        msg.data = [0] * 400
        self.guard.on_map(msg)
        self.assertIn("map reset", self.guard.fault)

    def test_mapper_restart_is_detected_even_with_identical_grid(self):
        self.inputs()
        ros_now = self.guard.get_clock().now().nanoseconds * 1e-9
        self.guard.on_map_session(String(data=json.dumps({"id": "map2", "stamp": ros_now})))
        self.assertIn("mapper restarted", self.guard.fault)
        self.assertNotIn("map", self.guard.samples)
        self.assertIn("stale or missing", self.evaluate())

    def startup_guard_status(self, speed=0.0):
        self.explorer.on_guard(
            String(
                data=json.dumps(
                    {
                        "stamp": self.explorer.ros_now(),
                        "ready": True,
                        "fault": "mapper restarted; restart exploration",
                        "speed": speed,
                    }
                )
            )
        )

    def test_new_stationary_mission_clears_restart_fault_without_authorizing_motion(self):
        self.inputs()
        self.guard.lease.value["enabled"] = False
        self.guard.fault = "mapper restarted; restart exploration"
        self.startup_guard_status()
        self.explorer.step()
        deadline = time.monotonic() + 2
        while self.guard.mission != self.explorer.mission and time.monotonic() < deadline:
            rclpy.spin_once(self.guard, timeout_sec=0.01)
        self.assertEqual(self.guard.mission, self.explorer.mission)
        self.assertIsNone(self.guard.fault)
        self.assertFalse(self.guard.lease.value["enabled"])
        self.assertIsNone(self.explorer.session)
        self.assertIsNone(self.explorer.planning)

    def test_mission_start_requires_standstill_and_fresh_inputs(self):
        self.inputs()
        self.startup_guard_status(speed=0.1)
        self.explorer.step()
        self.assertIsNone(self.explorer.origin)
        self.startup_guard_status()
        self.explorer.guard.stamp -= 1
        self.explorer.step()
        self.assertIsNone(self.explorer.origin)

    def test_existing_mission_does_not_clear_restart_fault(self):
        self.inputs()
        self.explorer.origin = (0, 0)
        self.guard.mission = self.explorer.mission
        self.guard.fault = "mapper restarted; restart exploration"
        self.startup_guard_status()
        self.explorer.step()
        rclpy.spin_once(self.guard, timeout_sec=0.05)
        self.assertIsNotNone(self.guard.fault)
        self.assertIsNone(self.explorer.session)
        self.assertIsNone(self.explorer.planning)

    def test_goal_behind_or_wrong_heading_is_not_success(self):
        self.explorer.goal = (0, 0, math.pi / 2)
        self.assertFalse(self.explorer.at_goal((2, 0, 0)))
        self.assertFalse(self.explorer.at_goal((0, 0, 0)))
        self.assertTrue(self.explorer.at_goal((0.05, 0, math.pi / 2)))

    def test_preflight_plan_is_not_treated_as_an_active_navigation_plan(self):
        from geometry_msgs.msg import PoseStamped

        self.inputs()
        self.explorer.goal = (0, 0, 0)
        self.explorer.origin = (0, 0)
        self.explorer.proposals = [(1, 1, (1, 0, 0))]
        path = RosPath()
        path.header.stamp, path.header.frame_id = self.stamp(), "map"
        pose = PoseStamped()
        pose.pose.position.x, pose.pose.orientation.w = 1.0, 1.0
        path.poses = [pose]
        self.explorer.on_plan(path)
        self.assertEqual(len(self.explorer.proposals), 1)
        self.assertFalse(self.explorer.path_valid)

    def test_previous_goal_plan_cannot_authorize_new_goal(self):
        self.inputs()
        self.explorer.goal = (1, 0, 0)
        self.explorer.origin = (0, 0)
        self.explorer.goal_stamp = self.explorer.ros_now() + 1
        path = RosPath()
        path.header.stamp, path.header.frame_id = self.stamp(), "map"
        from geometry_msgs.msg import PoseStamped

        pose = PoseStamped()
        pose.pose.position.x, pose.pose.orientation.w = 1.0, 1.0
        path.poses = [pose]
        self.explorer.on_plan(path)
        self.assertFalse(self.explorer.path_valid)

    def test_pause_revokes_lease_before_delayed_action_acceptance(self):
        from concurrent.futures import Future
        from types import SimpleNamespace

        acceptance = Future()
        client = SimpleNamespace(send_goal_async=lambda _: acceptance)
        self.explorer.session = ActionSession(client, object(), time.monotonic())
        self.explorer.on_resume(Bool(data=False))
        self.assertTrue(self.explorer.paused)
        self.assertFalse(self.explorer.session.active)
        self.assertIsNotNone(self.explorer.session.cancelled_at)


@unittest.skipUnless(rclpy, "ROS action tests run in the Nav2 image")
class RealActionTest(unittest.TestCase):
    def test_late_acceptance_is_cancelled_and_terminal_result_is_observed(self):
        rclpy.init()
        server_node, client_node = Node("delayed_server"), Node("delayed_client")
        executing = threading.Event()

        def accepted(_request):
            from rclpy.action import GoalResponse

            time.sleep(0.2)
            return GoalResponse.ACCEPT

        def execute(handle):
            executing.set()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and not handle.is_cancel_requested:
                time.sleep(0.01)
            if handle.is_cancel_requested:
                handle.canceled()
            else:
                handle.abort()
            return NavigateToPose.Result()

        server = ActionServer(
            server_node,
            NavigateToPose,
            "test_navigation",
            execute,
            goal_callback=accepted,
            cancel_callback=lambda _: CancelResponse.ACCEPT,
            callback_group=ReentrantCallbackGroup(),
        )
        client = ActionClient(client_node, NavigateToPose, "test_navigation")
        executor = MultiThreadedExecutor(num_threads=4)
        executor.add_node(server_node)
        executor.add_node(client_node)
        thread = threading.Thread(target=executor.spin)
        thread.start()
        try:
            self.assertTrue(client.wait_for_server(timeout_sec=3))
            session = ActionSession(client, NavigateToPose.Goal(), time.monotonic())
            session.cancel(time.monotonic(), "paused before acceptance")
            deadline = time.monotonic() + 4
            while not session.done and time.monotonic() < deadline:
                session.poll(time.monotonic())
                self.assertFalse(session.active)
                time.sleep(0.01)
            self.assertTrue(executing.is_set())
            self.assertEqual(session.status, 5)
            self.assertFalse(session.unsafe)
        finally:
            executor.shutdown()
            thread.join(timeout=2)
            server.destroy()
            client.destroy()
            server_node.destroy_node()
            client_node.destroy_node()
            rclpy.shutdown()


if __name__ == "__main__":
    unittest.main()
