#!/usr/bin/env python3
"""Subscribe to the vision unit's compressed camera topics, decode the
JPEG payload via OpenCV, and republish as raw `sensor_msgs/Image`
on fresh topics that cameracalibrator can consume:
`/<prefix>/<camera>/image_raw/compressed` to
`/<prefix>/<camera>/image_calibration`.

Usage: `decompress_stereo [<prefix> [<camera> ...]]`, the stereo pair,
`stereo left right`, by default; `decompress_stereo stereo hq` for the
camera of its own named `hq`.

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
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage, Image


class CompressedToRaw(Node):
    def __init__(self, prefix, cameras):
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

        for side in cameras:
            in_topic = f"/{prefix}/{side}/image_raw/compressed"
            out_topic = f"/{prefix}/{side}/image_calibration"
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
    prefix = sys.argv[1] if len(sys.argv) > 1 else "stereo"
    cameras = sys.argv[2:] or ["left", "right"]
    rclpy.init()
    node = CompressedToRaw(prefix, cameras)
    node.get_logger().info(f"decompressing {', '.join(cameras)} compressed → raw")
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    sys.exit(main())
