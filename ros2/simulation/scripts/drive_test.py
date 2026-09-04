"""Drive the simulated vehicle and check what odometry reports.

Two numbers matter, and both test geometry rather than motion:

  * 1.0 m/s for 5 s should advance ~5 m. A wheel radius that is wrong
    by 2x (as the previous model's was) reports 2x the distance while
    looking perfectly fine on screen.
  * At 1.0 m/s and 0.5 rad/s the turning radius should be v/omega = 2 m,
    and it must be achievable within the steering limit:
    R_min = wheelbase / tan(steering_limit).

It **asserts and exits non-zero**, like `perception_test.py`, so a
model change that breaks the drivetrain geometry fails a command rather
than needing someone to read three numbers and notice.

## /odom alone cannot catch a wrong wheel radius

`gazebo_ackermann.xacro` says a `wheel_radius` disagreeing with the
model "produces a vehicle that drives correctly and *reports* the wrong
distance". Under gz-sim 10's `AckermannSteering` that is not what
happens, and it was measured here rather than assumed: with
`<wheel_radius>` set to 0.1 against the model's real 0.0548, `/odom`
reported a flawless 1.000 m/s while the wheels turned at 10.0 rad/s —
so the car was actually crawling at 10.0 x 0.0548 = 0.548 m/s.

The radius cancels: the plugin divides the commanded speed by it to get
a joint velocity, then multiplies the joint velocity by it again to get
odometry. `/odom` is a command echo, and a check that only reads
`/odom` passes with the wheels off by any factor at all.

So the wheel radius is checked against `/joint_states`, which is
bridged already and reports the *physical* joint velocity. Ground speed
is that velocity times the real wheel radius, and it must agree with
what `/odom` claims. That comparison is the only thing here that would
have caught the bug the previous model shipped with.

## Tolerances

Speed is commanded directly and the simulator tracks it exactly — 1.000
and 2.000 m/s observed against 1.0 and 2.0 commanded — so 3% is
generous.

Radius is measured, not commanded: it comes out of the steering
geometry via v/omega, and observed 2.032 m and 3.927 m against 2.0 and
4.0 expected, i.e. under 2% off. 5% leaves room for tyre slip and for
the settle window ending mid-ramp, while still catching the kind of
error this exists for: the wheel radius that was once out by 2x, or a
steering limit that silently cannot achieve the commanded arc.

The straight leg additionally bounds yaw rate absolutely rather than as
a fraction, since the commanded rate is zero. Observed +0.000 rad/s,
so 0.02 is a measured bound.

Ground speed against odometry gets 5%: it is a product of two measured
quantities and the rear wheels slip a little in a corner, but the bug
it exists for is a factor of nearly two.
"""

import math
import sys
import time

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rclpy.node import Node
from sensor_msgs.msg import JointState


class Drive(Node):
    """Integrates arc length and unwrapped heading from /odom.

    Both are needed, and both are easy to get wrong:

      * **Arc, not chord.** The straight-line displacement between the
        first and last pose is not the distance travelled once the
        path curves. Over a 199-degree turn the chord is 0.57x the
        arc, which reads exactly like the vehicle driving at half the
        commanded speed.
      * **Unwrapped yaw.** A quaternion converts to a heading in
        [-pi, pi], so subtracting the first heading from the last
        silently loses a full turn — or flips its sign.
    """

    def __init__(self):
        super().__init__("drive_test")
        self.pub = self.create_publisher(Twist, "/cmd_vel", 10)
        self.create_subscription(Odometry, "/odom", self.on_odom, 10)
        self.create_subscription(JointState, "/joint_states", self.on_joints, 10)
        self.reset()

    def reset(self):
        self.arc = 0.0
        self.yaw_total = 0.0
        self.previous = None
        self.t0 = None
        self.t1 = None
        self.omega_sum = 0.0
        self.omega_count = 0

    def on_joints(self, message):
        # The rear pair only. They are unsteered, so the mean of the
        # two is the rear-axle centre speed exactly; a steered front
        # wheel rolls at v/cos(delta), which reads 1.3% fast at the
        # tightest arc here for no benefit.
        rates = [
            abs(velocity)
            for name, velocity in zip(message.name, message.velocity or [])
            if name in ("rear_left_wheel_joint", "rear_right_wheel_joint")
        ]
        if len(rates) == 2:
            self.omega_sum += sum(rates) / 2
            self.omega_count += 1

    def mean_omega(self):
        return self.omega_sum / self.omega_count if self.omega_count else None

    def on_odom(self, message):
        position = message.pose.pose.position
        q = message.pose.pose.orientation
        yaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        stamp = message.header.stamp.sec + message.header.stamp.nanosec * 1e-9

        if self.previous is not None:
            px, py, pyaw = self.previous
            self.arc += math.hypot(position.x - px, position.y - py)
            step = yaw - pyaw
            # Shortest way round, so a wrap at +/-pi does not register
            # as most of a revolution in the opposite direction.
            self.yaw_total += (step + math.pi) % (2 * math.pi) - math.pi

        self.previous = (position.x, position.y, yaw)
        if self.t0 is None:
            self.t0 = stamp
        self.t1 = stamp


# Speed is commanded and tracked exactly; radius is measured out of the
# steering geometry. See the moduledoc for the observed values these
# are drawn from.
SPEED_TOLERANCE = 0.03
RADIUS_TOLERANCE = 0.05
# Absolute, not fractional: the commanded rate is zero, so there is
# nothing to take a fraction of.
STRAIGHT_YAW_LIMIT = 0.02
GROUND_SPEED_TOLERANCE = 0.05
# The vehicle's real wheels, from the Traxxas Slash 4x4 specification
# and the `wheel_radius` property in
# `vehicles/ovcs_mini/description/ovcs_mini.urdf.xacro`. Stated here
# deliberately rather than read from the model: it is the independent
# expectation the model is being checked against, so a model that
# changed it would have to change this too, in a diff someone reads.
WHEEL_RADIUS = 0.0548


def within(measured, expected, fraction):
    return abs(measured - expected) <= abs(expected) * fraction


def verdict(ok):
    return "PASS " if ok else "FAIL "


def run(node, vx, wz, secs, label, settle=0.0):
    """Drive for `secs`, measuring only after `settle` seconds.

    The settle window matters: the vehicle ramps up under an
    acceleration limit, and including that ramp in a turning-radius
    measurement reports a radius that is a property of the ramp rather
    than of the steering geometry.
    """
    command = Twist()
    command.linear.x = vx
    command.angular.z = wz

    node.reset()
    start = time.time()
    while time.time() - start < settle:
        node.pub.publish(command)
        rclpy.spin_once(node, timeout_sec=0.02)

    # Discard the acceleration ramp and start the integration clean.
    node.reset()
    while time.time() - start < secs:
        node.pub.publish(command)
        rclpy.spin_once(node, timeout_sec=0.02)

    distance, dyaw, dt = node.arc, node.yaw_total, (node.t1 or 0) - (node.t0 or 0)
    omega = node.mean_omega()
    node.pub.publish(Twist())
    for _ in range(30):
        rclpy.spin_once(node, timeout_sec=0.02)

    print(f"{label}")

    if dt <= 0:
        print("    FAIL  no odometry received")
        return ["no odometry received during: " + label]

    speed = distance / dt
    yaw_rate = dyaw / dt
    print(
        f"    sim {dt:.2f}s  path {distance:.3f} m  "
        f"speed {speed:.3f} m/s  yaw rate {yaw_rate:+.3f} rad/s"
    )

    failures = []
    ok = within(speed, abs(vx), SPEED_TOLERANCE)
    print(f"    {verdict(ok)} speed")
    if not ok:
        failures.append(f"speed {speed:.3f} m/s, commanded {abs(vx):.3f}")

    if abs(wz) <= 1e-6:
        # Commanded straight. Observed +0.000 rad/s, so this is a real
        # bound rather than a guess: a steering offset or a left/right
        # wheel-radius mismatch curves the path while every speed
        # reading stays perfect.
        ok = abs(yaw_rate) <= STRAIGHT_YAW_LIMIT
        print(f"    {verdict(ok)} holds a straight line")
        if not ok:
            failures.append(f"yaw rate {yaw_rate:+.3f} rad/s while driving straight")
    else:
        # v/omega is the arc the command asks for. Comparing the
        # measured radius to it tests the steering geometry, which no
        # amount of correct speed would reveal.
        expected = abs(vx) / abs(wz)
        radius = distance / abs(dyaw) if abs(dyaw) > 0.05 else float("inf")
        print(f"    turning radius {radius:.3f} m, expected {expected:.3f}")
        ok = within(radius, expected, RADIUS_TOLERANCE)
        print(f"    {verdict(ok)} turning radius")
        if not ok:
            failures.append(f"radius {radius:.3f} m, expected {expected:.3f}")

    if omega is None:
        print("    FAIL  no joint states received")
        failures.append("no joint states received during: " + label)
    else:
        # The whole point of the file: physics against the plugin's own
        # arithmetic. See the moduledoc — /odom cannot catch this alone.
        ground = omega * WHEEL_RADIUS
        print(f"    wheels {omega:.2f} rad/s -> ground speed {ground:.3f} m/s")
        ok = within(ground, speed, GROUND_SPEED_TOLERANCE)
        print(f"    {verdict(ok)} wheel radius agrees with odometry")
        if not ok:
            failures.append(
                f"wheels turn at {omega:.2f} rad/s, i.e. {ground:.3f} m/s on "
                f"{WHEEL_RADIUS} m wheels, but odometry claims {speed:.3f} m/s"
            )

    return failures


def main():
    rclpy.init()
    node = Drive()
    # Let the vehicle settle onto its wheels before measuring.
    for _ in range(50):
        rclpy.spin_once(node, timeout_sec=0.02)

    failures = []
    failures += run(
        node, 1.0, 0.0, 7.0, "straight: 1.0 m/s, steady state  (expect 1.0 m/s)", settle=2.0
    )
    failures += run(
        node, 1.0, 0.5, 10.0, "turn: 1.0 m/s, 0.5 rad/s  (expect R = 2.0 m)", settle=3.0
    )
    failures += run(
        node, 2.0, 0.5, 10.0, "turn: 2.0 m/s, 0.5 rad/s  (expect R = 4.0 m)", settle=3.0
    )

    node.destroy_node()
    rclpy.shutdown()

    print()
    if failures:
        print(f"{len(failures)} failure(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("All drivetrain checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
