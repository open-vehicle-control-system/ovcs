"""Gamepad control for the simulated vehicle.

Separate from ``sim.launch.py`` because it is the only part of the
stack that needs a physical device. Compose treats a missing
``devices:`` entry as a hard failure, so keeping the joystick here
means ``docker compose up`` works on a machine with no controller
attached — which is most of them, and every CI runner.

Publishes ``/cmd_vel``, which the bridge forwards to Gazebo.
"""

import os

from launch import LaunchDescription
from launch_ros.actions import Node

CONFIG_DIR = "/opt/ovcs/config"


def generate_launch_description():
    use_sim_time = {"use_sim_time": True}

    return LaunchDescription(
        [
            Node(
                package="joy_linux",
                executable="joy_linux_node",
                parameters=[use_sim_time],
                output="screen",
            ),
            # The gamepad mapping is the one from the original traxxas
            # repo, reused unchanged — it was already correct for this
            # controller.
            Node(
                package="teleop_twist_joy",
                executable="teleop_node",
                parameters=[
                    os.path.join(CONFIG_DIR, "logitech_f310.yaml"),
                    use_sim_time,
                ],
                output="screen",
            ),
        ]
    )
