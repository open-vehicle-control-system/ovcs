"""Launch the camera-viewpoint supervisor on demand."""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument("use_sim_time", default_value="false"),
            DeclareLaunchArgument("dry_run", default_value="false"),
            ExecuteProcess(
                cmd=[
                    "python3",
                    "/opt/ovcs/forward_explore/forward_explore_node.py",
                    "--ros-args",
                    "--params-file",
                    "/opt/ovcs/config/forward_explore.yaml",
                    "-p",
                    ["use_sim_time:=", LaunchConfiguration("use_sim_time")],
                    "-p",
                    ["dry_run:=", LaunchConfiguration("dry_run")],
                ],
                output="screen",
            ),
        ]
    )
