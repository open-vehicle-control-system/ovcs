"""Frontier exploration for the OVCS Mini.

explore_lite reads RTAB-Map's grid (`/rtabmap/map`), picks the frontier
between free and unknown space that is cheapest to reach and largest,
and sends it to Nav2 as a NavigateToPose goal. It starts exploring as
soon as it runs: this is launched on demand, never at boot.
`explore/resume` (std_msgs/Bool) pauses and resumes it.
"""

from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    return LaunchDescription(
        [
            Node(
                package="explore_lite",
                executable="explore",
                name="explore_node",
                output="screen",
                parameters=["/opt/ovcs/config/explore.yaml"],
            )
        ]
    )
