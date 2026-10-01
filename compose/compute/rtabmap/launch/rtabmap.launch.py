"""RTAB-Map RGB-D mapping with a persistent database and a shared clock."""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, EmitEvent, ExecuteProcess, RegisterEventHandler
from launch.conditions import IfCondition, UnlessCondition
from launch.event_handlers import OnProcessExit
from launch.events import Shutdown
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
        parameters=[CONFIG, {"use_sim_time": LaunchConfiguration("use_sim_time")}],
        remappings=[("odom", "/odom")],
        arguments=arguments,
        condition=condition,
    )


def generate_launch_description():
    delete_db = LaunchConfiguration("delete_db_on_start")
    fresh_mapper = rtabmap(["--delete_db_on_start"], IfCondition(delete_db))
    persistent_mapper = rtabmap([], UnlessCondition(delete_db))
    return LaunchDescription(
        [
            DeclareLaunchArgument("delete_db_on_start", default_value="false"),
            DeclareLaunchArgument("use_sim_time", default_value="false"),
            Node(
                package="rtabmap_sync",
                executable="rgbd_sync",
                name="rgbd_sync",
                namespace="rtabmap",
                output="screen",
                parameters=[CONFIG, {"use_sim_time": LaunchConfiguration("use_sim_time")}],
                remappings=SYNC_REMAPPINGS,
            ),
            fresh_mapper,
            persistent_mapper,
            ExecuteProcess(
                cmd=[
                    "python3",
                    "/opt/ovcs/scripts/map_session.py",
                    "--ros-args",
                    "-p",
                    ["use_sim_time:=", LaunchConfiguration("use_sim_time")],
                ],
                output="screen",
            ),
            *[
                RegisterEventHandler(
                    OnProcessExit(
                        target_action=mapper,
                        on_exit=[EmitEvent(event=Shutdown(reason="mapper exited"))],
                    )
                )
                for mapper in (fresh_mapper, persistent_mapper)
            ],
        ]
    )
