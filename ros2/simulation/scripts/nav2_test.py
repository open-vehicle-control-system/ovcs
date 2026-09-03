"""Drive the simulated vehicle with Nav2 and check what it commanded.

Reaching the goal is the weakest of the three things checked here, and
on its own it would pass with a configuration that is wrong in ways
that matter on a real car.

## What this actually guards

1. **The goal is reached.** Proves the whole chain: bt_navigator ->
   planner -> MPPI -> `/cmd_vel_nav` (TwistStamped) -> the stamped
   bridge -> `AckermannSteering`. Any broken link here shows up as a
   goal that never completes.

2. **The turning radius is honoured.** For every commanded pair,
   `|wz| <= |vx| / min_turning_r`. This is the assertion that catches
   `motion_model` being unset or renamed, which silently reverts MPPI
   to `mppi::OmniMotionModel` — holonomic, and happy to command
   sideways and spin-in-place velocities the vehicle cannot produce.
   The car still reaches the goal in simulation when that happens,
   because Gazebo's plugin quietly ignores what it cannot do. On the
   real vehicle it would be commanding arcs tighter than the steering
   can cut.

3. **No in-place rotation is commanded.** `vx` at zero with `wz`
   nonzero is the one command an Ackermann vehicle can never execute.
   It is what `Spin` recovery produces, and what a goal checker
   demanding a final heading produces. Both abort navigation on a car.

Check 2 is the reason this file exists. It is the only one that fails
when the kinematic model is wrong, and the whole point of running Nav2
against this vehicle rather than a differential-drive one.

## Two goals, because one cannot test both things

An easy goal never exercises the radius limit: a goal 3 m ahead and 1 m
across needs a 5 m arc, and a completely unconstrained controller
drives it at 0.72x the limit — under the threshold, so the check
passes. Measured, not assumed.

A tight goal does exercise it, but the *correctly* configured vehicle
then struggles to arrive: at a required 0.93 m arc against a 0.57 m
minimum, the Ackermann run needed 1317 commands and still timed out
0.46 m short. Asserting arrival there would be a gate that fails on
good configuration.

So each goal is asked only what it can answer:

  * **reach** — 3 m ahead, 1 m across. Arrival is required. The
    kinematic checks run too, but they are not what this leg is for.
  * **turn** — 0.8 m ahead, 1.4 m across, a required arc of 0.93 m
    against a 0.57 m minimum. Arrival is **not** required: the point is
    what gets commanded while trying, and a car legitimately needs to
    shuffle. The kinematic checks are the whole assertion.

## Tolerances

Arrival allows 0.60 m against `nav2.yaml`'s `xy_goal_tolerance` of
0.30. MPPI stops the moment the checker is satisfied, so asserting
tighter than the thing under test is a flaky restatement of it.

The radius check gets 10% of slack. MPPI clamps the control sequence it
samples, so a published command should satisfy the constraint exactly —
the Ackermann run peaks at exactly 1.00x. The margin covers rounding,
and is nowhere near the 404x an unconstrained model reaches.

`STANDSTILL_WZ` is 0.15 rad/s to separate two different things that
both show up as yaw near zero speed. Momentary transients as the
vehicle starts and stops reach 0.081; a genuine attempt to rotate on
the spot reached 0.359. A handful of transient samples is allowed for
the same reason.
"""

import math
import sys
import time

import rclpy
from geometry_msgs.msg import TwistStamped
from nav2_msgs.action import NavigateToPose
from nav_msgs.msg import Odometry
from rclpy.action import ActionClient
from rclpy.node import Node
from rclpy.parameter import Parameter

# From vehicles/ovcs_mini/description/ovcs_mini.urdf.xacro:
#   wheelbase / tan(steering_limit) = 0.324 / tan(0.52) = 0.566 m
# nav2.yaml rounds that up to 0.6 for margin. Stated here independently
# so a change to one has to be a change to both, in a diff someone reads.
MIN_TURNING_RADIUS = 0.6
RADIUS_SLACK = 1.10

GOAL_TOLERANCE = 0.60
GOAL_TIMEOUT = 90.0

# Below this speed a commanded yaw rate is an in-place rotation, which
# this vehicle cannot perform at all. See the tolerance note above for
# where these two numbers come from.
STANDSTILL_VX = 0.05
STANDSTILL_WZ = 0.15
# Start/stop transients produce a few of these legitimately.
STANDSTILL_ALLOWANCE = 8

# (label, dx, dy, arrival required). See "Two goals" above.
GOALS = [
    ("reach: 3.0 m ahead, 1.0 m across", 3.0, 1.0, True),
    ("turn: 0.8 m ahead, 1.4 m across (0.93 m arc vs 0.57 m minimum)", 0.8, 1.4, False),
]


class Navigator(Node):
    def __init__(self):
        super().__init__("nav2_test")
        self.set_parameters([Parameter("use_sim_time", value=True)])
        self.client = ActionClient(self, NavigateToPose, "navigate_to_pose")
        self.create_subscription(Odometry, "/odom", self.on_odom, 10)
        # TwistStamped, not Twist. Subscribing with the wrong type here
        # would report zero commands and pass every check vacuously.
        self.create_subscription(TwistStamped, "/cmd_vel_nav", self.on_cmd, 30)
        self.pose = None
        self.commands = []

    def on_odom(self, message):
        position = message.pose.pose.position
        self.pose = (position.x, position.y)

    def on_cmd(self, message):
        self.commands.append((message.twist.linear.x, message.twist.angular.z))

    def settle(self, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            rclpy.spin_once(self, timeout_sec=0.05)


def verdict(ok):
    return "PASS " if ok else "FAIL "


def check(failures, ok, label, detail):
    print(f"  {verdict(ok)} {label}: {detail}")
    if not ok:
        failures.append(f"{label} — {detail}")


def navigate(node, label, dx, dy, must_arrive, failures):
    """Send one goal and check what was commanded on the way."""
    node.commands = []
    node.settle(1.0)
    start = node.pose
    target = (start[0] + dx, start[1] + dy)

    goal = NavigateToPose.Goal()
    goal.pose.header.frame_id = "odom"
    goal.pose.header.stamp = node.get_clock().now().to_msg()
    goal.pose.pose.position.x = target[0]
    goal.pose.pose.position.y = target[1]
    goal.pose.pose.orientation.w = 1.0

    print()
    print(label)

    send = node.client.send_goal_async(goal)
    rclpy.spin_until_future_complete(node, send, timeout_sec=20.0)
    handle = send.result()

    if handle is None or not handle.accepted:
        check(failures, False, "goal accepted", "Nav2 rejected the goal")
        return

    result = handle.get_result_async()
    deadline = time.time() + GOAL_TIMEOUT
    while time.time() < deadline and not result.done():
        rclpy.spin_once(node, timeout_sec=0.1)

    status = result.result().status if result.done() else None
    error = math.hypot(node.pose[0] - target[0], node.pose[1] - target[1])

    if must_arrive:
        check(
            failures,
            status == 4 and error <= GOAL_TOLERANCE,
            "goal reached",
            f"{error:.2f} m away, status {status if status else 'timed out'} "
            f"(tolerance {GOAL_TOLERANCE:.2f})",
        )
    else:
        # Reported, not asserted: a car legitimately needs to shuffle
        # for an arc this tight, and demanding arrival here would fail
        # on correct configuration. See the module docstring.
        print(f"        (arrival not asserted: {error:.2f} m away, status {status})")

    if not node.commands:
        check(failures, False, "commands observed", "nothing published on /cmd_vel_nav")
        return

    # ── the turning radius ───────────────────────────────────────────
    worst_ratio, worst = 0.0, (0.0, 0.0)
    for vx, wz in node.commands:
        allowed = abs(vx) / MIN_TURNING_RADIUS
        ratio = abs(wz) / allowed if allowed > 1e-9 else (0.0 if abs(wz) < 1e-9 else math.inf)
        if ratio > worst_ratio:
            worst_ratio, worst = ratio, (vx, wz)

    check(
        failures,
        worst_ratio <= RADIUS_SLACK,
        "turning radius honoured",
        f"worst |wz| was {worst_ratio:.2f}x the limit at "
        f"vx={worst[0]:.3f}, wz={worst[1]:.3f} (R_min {MIN_TURNING_RADIUS} m)",
    )

    # ── in-place rotation ────────────────────────────────────────────
    spins = [
        (vx, wz)
        for vx, wz in node.commands
        if abs(vx) < STANDSTILL_VX and abs(wz) > STANDSTILL_WZ
    ]
    check(
        failures,
        len(spins) <= STANDSTILL_ALLOWANCE,
        "no in-place rotation commanded",
        f"{len(spins)} of {len(node.commands)} commands asked for yaw at a standstill "
        f"(allowance {STANDSTILL_ALLOWANCE})"
        + (f", worst wz={max(abs(w) for _, w in spins):.3f}" if spins else ""),
    )

    vxs = [c[0] for c in node.commands]
    print(f"        vx range {min(vxs):+.3f} .. {max(vxs):+.3f} m/s")


def main():
    rclpy.init()
    node = Navigator()
    node.settle(3.0)

    failures = []

    if node.pose is None:
        print("  FAIL  no odometry — is the simulator running?")
        rclpy.shutdown()
        return 1

    if not node.client.wait_for_server(timeout_sec=30.0):
        print("  FAIL  navigate_to_pose action server never appeared")
        print("        Nav2 did not finish its lifecycle bringup.")
        rclpy.shutdown()
        return 1

    print(f"Start pose: ({node.pose[0]:.2f}, {node.pose[1]:.2f})")

    for label, dx, dy, must_arrive in GOALS:
        navigate(node, label, dx, dy, must_arrive, failures)

    rclpy.shutdown()

    print()
    if failures:
        print(f"{len(failures)} failure(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("All Nav2 checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
