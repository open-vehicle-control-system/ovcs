"""Bring up the OVCS Mini in Gazebo Harmonic.

Starts four things, in the order they depend on each other:

1. ``robot_state_publisher`` — expands the xacro and publishes
   ``/robot_description`` plus the fixed transforms.
2. ``gz sim`` — the physics server, loading the world.
3. ``ros_gz_bridge`` — the only path between the Gazebo transport and
   ROS. Nothing crosses that boundary unless it is listed here.
4. ``ros_gz_sim create`` — spawns the robot from
   ``/robot_description``, which is why it comes last.

Gazebo runs **server-only** here; the GUI is a separate compose
service. ``use_sim_time`` is set on every ROS node. Without it, nodes stamp
messages with wall-clock time while the physics runs on its own clock;
TF then rejects lookups as "extrapolation into the future" and the
failure looks like a transform problem rather than a clock one.
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.conditions import IfCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import Command, LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue

VEHICLES_DIR = os.environ.get("OVCS_VEHICLES_DIR", "/opt/ovcs/vehicles")
WORLDS_DIR = "/opt/ovcs/worlds"
CONFIG_DIR = "/opt/ovcs/config"

# Topics that cross between Gazebo and ROS, and which way they go.
# The direction arrow matters:
#   @  bidirectional
#   [  gz -> ros
#   ]  ros -> gz
BRIDGE_TOPICS = [
    # The physics clock. First because everything else depends on
    # nodes agreeing what time it is.
    "/clock@rosgraph_msgs/msg/Clock[gz.msgs.Clock",
    "/odom@nav_msgs/msg/Odometry[gz.msgs.Odometry",
    "/tf@tf2_msgs/msg/TFMessage[gz.msgs.Pose_V",
    "/joint_states@sensor_msgs/msg/JointState[gz.msgs.Model",
]

# The drive command is separate because its Gazebo-side name contains
# the model name. AckermannSteering has no verified tag for renaming
# its command topic, so it keeps the documented default
# `/model/<name>/cmd_vel` and the bridge remaps it to `/cmd_vel` — an
# ignored tag would leave the car silently immobile.
CMD_VEL_GZ = "/cmd_vel@geometry_msgs/msg/Twist]gz.msgs.Twist"


def generate_launch_description():
    use_sim_time = {"use_sim_time": True}

    world = LaunchConfiguration("world")
    teleop = LaunchConfiguration("teleop")
    vehicle = LaunchConfiguration("vehicle")

    # `value_type=str` is load-bearing. Without it launch tries to
    # parse the expanded URDF as YAML and fails on the first colon in
    # the XML, with an error that says nothing about xacro.
    # <vehicles>/<vehicle>/<vehicle>.urdf.xacro — one directory per
    # vehicle, named after it.
    model = PathJoinSubstitution([VEHICLES_DIR, vehicle, [vehicle, ".urdf.xacro"]])

    # `value_type=str` is load-bearing. Without it launch tries to
    # parse the expanded URDF as YAML and fails on the first colon in
    # the XML, with an error that says nothing about xacro.
    robot_description = ParameterValue(
        Command(["xacro ", model]), value_type=str
    )

    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "vehicle",
                default_value="ovcs_mini",
                description=(
                    "Which vehicle to spawn. Names a directory under "
                    "simulation/vehicles/ containing <name>.urdf.xacro."
                ),
            ),
            DeclareLaunchArgument(
                "world",
                default_value=os.path.join(WORLDS_DIR, "empty.sdf"),
                description="SDF world to load.",
            ),
            DeclareLaunchArgument(
                "teleop",
                default_value="true",
                description="Run joy + teleop_twist_joy to drive from a gamepad.",
            ),
            Node(
                package="robot_state_publisher",
                executable="robot_state_publisher",
                output="screen",
                parameters=[
                    {"robot_description": robot_description},
                    use_sim_time,
                ],
            ),
            # `-s` is server-only, and it is not optional here:
            # gz_sim.launch.py starts the GUI as well by default, and
            # in a container with no display Qt calls qFatal and takes
            # the whole simulation down with it. The GUI is a separate
            # compose service that mounts an X socket.
            #
            # `-r` runs the world immediately; without it the
            # simulation loads paused and nothing moves, which reads
            # exactly like a broken drive plugin.
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(
                    PathJoinSubstitution(
                        [
                            get_package_share_directory("ros_gz_sim"),
                            "launch",
                            "gz_sim.launch.py",
                        ]
                    )
                ),
                launch_arguments={
                    "gz_args": ["-s -r -v 2 ", world],
                    "on_exit_shutdown": "true",
                }.items(),
            ),
            Node(
                package="ros_gz_bridge",
                executable="parameter_bridge",
                arguments=BRIDGE_TOPICS
                + [["/model/", vehicle, CMD_VEL_GZ]],
                parameters=[use_sim_time],
                remappings=[(["/model/", vehicle, "/cmd_vel"], "/cmd_vel")],
                output="screen",
            ),
            Node(
                package="ros_gz_sim",
                executable="create",
                arguments=[
                    "-topic",
                    "/robot_description",
                    "-name",
                    vehicle,
                    # Dropped from a couple of centimetres so the
                    # suspension-free wheels settle onto the ground
                    # instead of starting interpenetrated.
                    "-z",
                    "0.02",
                ],
                parameters=[use_sim_time],
                output="screen",
            ),
            Node(
                package="joy_linux",
                executable="joy_linux_node",
                condition=IfCondition(teleop),
                parameters=[use_sim_time],
                output="screen",
            ),
            # The gamepad mapping is the one from the original traxxas
            # repo, reused unchanged — it was already correct for this
            # controller.
            Node(
                package="teleop_twist_joy",
                executable="teleop_node",
                condition=IfCondition(teleop),
                parameters=[
                    os.path.join(CONFIG_DIR, "logitech_f310.yaml"),
                    use_sim_time,
                ],
                output="screen",
            ),
        ]
    )
