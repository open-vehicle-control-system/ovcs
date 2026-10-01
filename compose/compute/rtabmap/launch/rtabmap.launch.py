"""RTAB-Map in RGB-D mode for the OVCS Mini.

`rgbd_sync` pairs the rectified left image (`/stereo/left/image_rect`,
JPEG) and the depth image (`/stereo/depth/image_rect`) exactly: they
share their stamp. Their intrinsics are `/stereo/depth/camera_info`,
since `/stereo/left/camera_info` describes the raw image. `rtabmap`
pairs the bundle with `/odom` approximately, the two coming from
different boards at different rates, and reads the odometry's
covariances. `odom_frame_id` stays unset: setting it makes rtabmap
read the odometry from TF, which carries none.

Outputs: `/rtabmap/map` (`nav_msgs/OccupancyGrid`), `map -> odom` on `/tf`,
and the database at `database_path`.

Every start begins a new map (`delete_db_on_start`, default true): a
database written by an interrupted session can fail to reload, with a
fatal "Memory::addLink() Condition (fromS->getWeight() >= 0 ...)", and
the node then dies at every start. `delete_db_on_start:=false` keeps
the previous map.
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition, UnlessCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

CONFIG = "/opt/ovcs/config/rtabmap.yaml"

SYNC_REMAPPINGS = [
    ("rgb/image", "/stereo/left/image_rect"),
    ("rgb/camera_info", "/stereo/depth/camera_info"),
    ("depth/image", "/stereo/depth/image_rect"),
]


def rtabmap(arguments, condition):
    return Node(
        package="rtabmap_slam",
        executable="rtabmap",
        name="rtabmap",
        namespace="rtabmap",
        output="screen",
        parameters=[CONFIG],
        remappings=[("odom", "/odom")],
        arguments=arguments,
        condition=condition,
    )


def generate_launch_description():
    delete_db = LaunchConfiguration("delete_db_on_start")
    return LaunchDescription(
        [
            DeclareLaunchArgument("delete_db_on_start", default_value="true"),
            Node(
                package="rtabmap_sync",
                executable="rgbd_sync",
                name="rgbd_sync",
                namespace="rtabmap",
                output="screen",
                parameters=[CONFIG],
                remappings=SYNC_REMAPPINGS,
            ),
            rtabmap(["--delete_db_on_start"], IfCondition(delete_db)),
            rtabmap([], UnlessCondition(delete_db)),
        ]
    )
