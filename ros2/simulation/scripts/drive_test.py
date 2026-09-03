"""Drive the simulated vehicle and measure what odometry reports.

Two numbers matter, and both test geometry rather than motion:

  * 1.0 m/s for 5 s should advance ~5 m. A wheel radius that is wrong
    by 2x (as the previous model's was) reports 2x the distance while
    looking perfectly fine on screen.
  * At 1.0 m/s and 0.5 rad/s the turning radius should be v/omega = 2 m,
    and it must be achievable within the steering limit:
    R_min = wheelbase / tan(steering_limit).
"""

import math
import time

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rclpy.node import Node


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
        self.reset()

    def reset(self):
        self.arc = 0.0
        self.yaw_total = 0.0
        self.previous = None
        self.t0 = None
        self.t1 = None

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
    node.pub.publish(Twist())
    for _ in range(30):
        rclpy.spin_once(node, timeout_sec=0.02)

    if dt <= 0:
        print(f"{label}: NO ODOMETRY RECEIVED")
        return

    print(f"{label}")
    print(
        f"    sim {dt:.2f}s  path {distance:.3f} m  "
        f"speed {distance / dt:.3f} m/s  yaw rate {dyaw / dt:+.3f} rad/s"
    )
    if abs(dyaw) > 0.05:
        print(f"    turning radius {distance / abs(dyaw):.3f} m")


def main():
    rclpy.init()
    node = Drive()
    # Let the vehicle settle onto its wheels before measuring.
    for _ in range(50):
        rclpy.spin_once(node, timeout_sec=0.02)

    run(node, 1.0, 0.0, 7.0, "straight: 1.0 m/s, steady state  (expect 1.0 m/s)", settle=2.0)
    run(node, 1.0, 0.5, 10.0, "turn: 1.0 m/s, 0.5 rad/s  (expect R = 2.0 m)", settle=3.0)
    run(node, 2.0, 0.5, 10.0, "turn: 2.0 m/s, 0.5 rad/s  (expect R = 4.0 m)", settle=3.0)

    node.destroy_node()
    rclpy.shutdown()


if __name__ == "__main__":
    main()
