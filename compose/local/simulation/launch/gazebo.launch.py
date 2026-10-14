"""Bring up a vehicle in Gazebo Jetty, for the VMS to drive.

Starts, in the order they depend on each other:

1. ``robot_state_publisher`` — expands the xacro and publishes
   ``/robot_description`` plus the fixed transforms.
2. ``gz sim`` — the physics server, loading the world.
3. ``ros_gz_bridge`` — the only path between the Gazebo transport and
   ROS. Nothing crosses that boundary unless it is listed here.
4. one ``image_bridge`` per camera.
5. ``ros_gz_sim create`` — spawns the robot from
   ``/robot_description``, which is why it comes last.

Nothing here commands the vehicle. The VMS does, over virtual CAN,
through the simulated hardware in the vehicle's ROS bridge
(``RosBridge.Simulator.Hardware``), which hands Gazebo the resulting motion
on ``/simulator/drive``. The bridge also owns ``/odom`` and
``odom -> base_link``, so the steering system's own odometry is not
bridged.

Gazebo runs **server-only** here; the GUI is a separate compose
service. ``use_sim_time`` is set on every ROS node. Without it, nodes stamp
messages with wall-clock time while the physics runs on its own clock;
TF then rejects lookups as "extrapolation into the future" and the
failure looks like a transform problem rather than a clock one.
"""

import os

import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import Command, LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue

VEHICLES_DIR = os.environ.get("OVCS_VEHICLES_DIR", "/opt/ovcs/vehicles")
WORLDS_DIR = "/opt/ovcs/worlds"

# Topics that cross between Gazebo and ROS, and which way they go.
# The direction arrow matters:
#   @  bidirectional
#   [  gz -> ros
#   ]  ros -> gz
# The vehicle's sensors are added from its description/simulation.yaml.
BRIDGE_TOPICS = [
    # The physics clock. First because everything else depends on
    # nodes agreeing what time it is.
    "/clock@rosgraph_msgs/msg/Clock[gz.msgs.Clock",
    "/joint_states@sensor_msgs/msg/JointState[gz.msgs.Model",
    # Ground truth, from the model's OdometryPublisher; nothing
    # navigates by it.
    "/simulator/odom@nav_msgs/msg/Odometry[gz.msgs.Odometry",
]

# Cameras (the vehicle's `camera_topics`) go through `ros_gz_image
# image_bridge`, not the parameter bridge, and the reason is bandwidth
# rather than tidiness.
#
# A 480x270 rgb8 frame is 389 KB. At 30 Hz that is 11.6 MB/s of raw
# pixels, and putting it on the Zenoh fabric does not work: measured
# here, a subscriber that cannot drain it that fast gets **one frame
# every 15 seconds** — zenoh drops what the link cannot carry, so the
# failure looks like a broken topic rather than a saturated one.
#
# image_bridge publishes through image_transport, which offers a
# `/compressed` JPEG variant, the same thing the real vehicle publishes,
# and a fraction of the size. Raw pixels stay inside gz-transport, where
# they are cheap.

# The drive command's Gazebo-side name contains the model name.
# AckermannSteering has no verified tag for renaming its command topic,
# so it keeps the documented default `/model/<name>/cmd_vel` and the
# bridge remaps it to `/simulator/drive` — an ignored tag would leave
# the car silently immobile.
DRIVE_GZ = "/cmd_vel@geometry_msgs/msg/Twist]gz.msgs.Twist"


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "vehicle",
                description=(
                    "Which vehicle to spawn. Names a directory under "
                    "$OVCS_VEHICLES_DIR (default /opt/ovcs/vehicles) "
                    "containing <name>.urdf.xacro and simulation.yaml; "
                    "compose mounts vehicles/<name>/description there."
                ),
            ),
            DeclareLaunchArgument(
                "world",
                default_value=os.path.join(WORLDS_DIR, "workshop.sdf"),
                description=(
                    "SDF world to load. `workshop.sdf` is textured and "
                    "has obstacles at known distances, which stereo "
                    "needs; `empty.sdf` is flat and featureless and "
                    "will produce no disparity at all."
                ),
            ),
            OpaqueFunction(function=spawn),
        ]
    )


def spawn(context):
    """Everything that depends on the vehicle, once its name is known."""
    use_sim_time = {"use_sim_time": True}

    world = LaunchConfiguration("world")
    vehicle = context.perform_substitution(LaunchConfiguration("vehicle"))
    vehicle_dir = os.path.join(VEHICLES_DIR, vehicle)

    with open(os.path.join(vehicle_dir, "simulation.yaml")) as file:
        gazebo = yaml.safe_load(file)["gazebo"]

    # `value_type=str` is load-bearing. Without it launch tries to
    # parse the expanded URDF as YAML and fails on the first colon in
    # the XML, with an error that says nothing about xacro.
    robot_description = ParameterValue(
        Command(["xacro ", os.path.join(vehicle_dir, f"{vehicle}.urdf.xacro")]),
        value_type=str,
    )

    return [
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
            name="parameter_bridge",
            arguments=BRIDGE_TOPICS + gazebo["bridge_topics"] + [f"/model/{vehicle}{DRIVE_GZ}"],
            parameters=[use_sim_time],
            remappings=[(f"/model/{vehicle}/cmd_vel", "/simulator/drive")],
            output="screen",
        ),
        # One image_bridge per camera; each offers raw and
        # compressed, and image_transport only actually sends a
        # transport someone has subscribed to.
        *[
            Node(
                package="ros_gz_image",
                executable="image_bridge",
                arguments=[topic],
                parameters=[use_sim_time],
                output="screen",
            )
            for topic in gazebo["camera_topics"]
        ],
        Node(
            package="ros_gz_sim",
            executable="create",
            arguments=[
                "-topic",
                "/robot_description",
                "-name",
                vehicle,
                "-z",
                str(gazebo["spawn_z"]),
            ],
            parameters=[use_sim_time],
            output="screen",
        ),
    ]
