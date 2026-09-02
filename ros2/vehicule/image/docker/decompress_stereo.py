#!/usr/bin/env python3
"""Subscribe to the bridge's stereo compressed topics, decode the
JPEG payload via OpenCV, and republish as raw `sensor_msgs/Image`
on a fresh pair of topics that cameracalibrator can consume.

We use this instead of `image_transport republish` because the
latter's CompressedImage subscriber and our Elixir bridge's
CompressedImage publisher disagree on the rmw_zenoh type hash, so
no frames are ever delivered. rclpy goes through a different
subscription path that does work with our hash.
"""

import sys

import cv2
import numpy as np
import rclpy
from cv_bridge import CvBridge
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import CompressedImage, Image


class CompressedToRaw(Node):
    def __init__(self):
        super().__init__("compressed_to_raw")
        self.bridge = CvBridge()

        # rmw_zenoh works best with sensor-data QoS (best-effort,
        # keep-last). cameracalibrator on the consumer side uses
        # the system default; sensor-data on the publisher is
        # compatible with both.
        qos = QoSProfile(
            depth=5,
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
        )

        for side in ("left", "right"):
            in_topic = f"/stereo/{side}/image_raw/compressed"
            out_topic = f"/stereo/{side}/image_calibration"
            pub = self.create_publisher(Image, out_topic, qos)
            self.create_subscription(
                CompressedImage,
                in_topic,
                self._make_callback(side, pub),
                qos,
            )
            self.get_logger().info(f"  {in_topic} → {out_topic}")

    def _make_callback(self, side, pub):
        def callback(msg: CompressedImage):
            data = np.frombuffer(msg.data, dtype=np.uint8)
            frame = cv2.imdecode(data, cv2.IMREAD_COLOR)
            if frame is None:
                self.get_logger().warn(f"{side}: imdecode failed")
                return
            raw = self.bridge.cv2_to_imgmsg(frame, encoding="bgr8")
            raw.header = msg.header
            pub.publish(raw)

        return callback


def main():
    rclpy.init()
    node = CompressedToRaw()
    node.get_logger().info("decompressing stereo compressed → raw")
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    sys.exit(main())
