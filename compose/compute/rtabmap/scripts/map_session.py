"""Identify mapper process lifetimes, including restarts that preserve map dimensions."""

import json
import uuid

import rclpy
from rclpy.clock import Clock, ClockType
from rclpy.node import Node
from std_msgs.msg import String


def main():
    rclpy.init()
    node = Node("map_session", namespace="rtabmap")
    publisher = node.create_publisher(String, "/rtabmap/session", 1)
    identity = str(uuid.uuid4())

    def publish():
        publisher.publish(
            String(
                data=json.dumps(
                    {"id": identity, "stamp": node.get_clock().now().nanoseconds * 1e-9}
                )
            )
        )

    node.create_timer(0.5, publish, clock=Clock(clock_type=ClockType.STEADY_TIME))
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
