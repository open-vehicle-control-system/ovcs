"""Synthetic map/cloud inputs for the stationary virtual-CAN planner-loop check."""

import json
import os
import struct
import sys

import rclpy
from geometry_msgs.msg import TransformStamped
from nav_msgs.msg import OccupancyGrid
from rclpy.executors import SingleThreadedExecutor
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile
from sensor_msgs.msg import PointCloud2, PointField
from std_msgs.msg import String
from tf2_ros import TransformBroadcaster

sys.path.insert(0, "/opt/ovcs/forward_explore")
from forward_explore_node import ForwardExplore


class Fixture(Node):
    def __init__(self):
        super().__init__("virtual_can_perception_fixture")
        self.map = self.create_publisher(
            OccupancyGrid,
            "/rtabmap/map",
            QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL),
        )
        self.cloud = self.create_publisher(PointCloud2, "/stereo/points", 10)
        self.session = self.create_publisher(String, "/rtabmap/session", 1)
        self.tf = TransformBroadcaster(self)
        self.create_timer(0.1, self.tick)

    def tick(self):
        stamp = self.get_clock().now().to_msg()
        transform = TransformStamped()
        transform.header.frame_id, transform.child_frame_id = "map", "odom"
        transform.header.stamp = stamp
        transform.transform.rotation.w = 1.0
        self.tf.sendTransform(transform)
        grid = OccupancyGrid()
        grid.header.frame_id, grid.header.stamp = "map", stamp
        grid.info.resolution, grid.info.width, grid.info.height = 0.1, 100, 100
        grid.info.origin.position.x = grid.info.origin.position.y = -5.0
        grid.info.origin.orientation.w = 1.0
        grid.data = [
            0 if 20 <= i < 80 and 20 <= j < 80 else -1 for j in range(100) for i in range(100)
        ]
        self.map.publish(grid)
        cloud = PointCloud2()
        cloud.header.frame_id, cloud.header.stamp = "rear_axle", stamp
        cloud.width = cloud.height = 1
        cloud.fields = [
            PointField(name=name, offset=offset, datatype=PointField.FLOAT32, count=1)
            for name, offset in (("x", 0), ("y", 4), ("z", 8))
        ]
        cloud.point_step = cloud.row_step = 12
        cloud.is_dense, cloud.data = True, struct.pack("<fff", 2.0, 0.0, 0.0)
        self.cloud.publish(cloud)
        self.session.publish(
            String(
                data=json.dumps(
                    {
                        "id": "virtual-can-fixture",
                        "stamp": self.get_clock().now().nanoseconds * 1e-9,
                    }
                )
            )
        )


def main():
    if os.environ.get("OVCS_OFFLINE_FIXTURE") != "1":
        raise SystemExit("This fixture is only for the stationary virtual-CAN verifier.")
    rclpy.init()
    fixture, explorer = Fixture(), ForwardExplore()
    executor = SingleThreadedExecutor()
    executor.add_node(fixture)
    executor.add_node(explorer)
    try:
        executor.spin()
    except KeyboardInterrupt:
        pass
    finally:
        executor.shutdown()
        fixture.destroy_node()
        explorer.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
