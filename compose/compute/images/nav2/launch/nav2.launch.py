"""Nav2 — launched identically on the vehicle, on a dev machine, and
against the simulator.

One parameter file (`/opt/ovcs/config/nav2.yaml`, from
`vehicles/<vehicle>/nav2/`, the vehicle's truth) and one
switch: `use_sim_time:=true` overlays the file for a simulated run,
because a params fork would drift and stop the simulator being
evidence about the vehicle.

Four lifecycle servers and a velocity smoother, plus a manager to
bring them up. Deliberately *not* `nav2_bringup`: there is no such
package in the Lyrical archive, and its launch file would pull in
map_server and AMCL, neither of which this configuration uses. See
the vehicle's `nav2.yaml` for why there is no map.

The velocity output needs saying out loud, because it is the one thing
that silently does nothing if it is wrong. Nav2 1.5.1 publishes
`geometry_msgs/TwistStamped`, not `Twist` —
`nav2_util::TwistPublisher` reads `enable_stamped_cmd_vel` with a
default of **true**, and `controller_server::publishVelocity` takes a
`TwistStamped`. (The doc comment in `twist_publisher.hpp` still claims
unstamped is the default; the code disagrees, and the code wins.)

So Nav2's final output is `/cmd_vel_nav`, as `TwistStamped`, and the
vehicle's ROS bridge subscribes to it with that type, on the vehicle
and against the simulator alike. It reaches the VMS as `0x2B1`, the
velocity command, apart from a joystick's `0x2B0`; the control level
manager arbitrates between them.

The controller and the behaviours do not publish `/cmd_vel_nav`
themselves: they publish `/cmd_vel_nav_raw`, and the velocity smoother
republishes it on `/cmd_vel_nav` with its limits and deadband applied.
The deadband zeroes noise; a vehicle whose `RosVelocityCommand` sets
`:min_speed_m_s` floors slower non-zero speeds there, see its
`nav2.yaml`.

`robot_state_publisher` publishes the vehicle's URDF
(`/opt/ovcs/description/robot.urdf`, expanded from
`vehicles/<vehicle>/description/`): its fixed joints on `/tf_static`,
which place the frames the sensors are stamped with on `base_link`.
`robot_state_publisher:=false` leaves it to the simulator, whose launch
runs its own.

`octomap_server` accumulates the stereo cloud into a 3D occupancy map in
`odom`, for the displays rather than for Nav2. It runs only for a vehicle
whose `nav2/` directory has an `octomap.yaml`, and reads `octomap_cloud`,
the stereo camera's `/stereo/points` by default. Its occupied voxels'
centres are on `/octomap/point_cloud_centers`, as a `PointCloud2`.

Both sides are throttled to `octomap_rate`. It republishes the whole map
after every cloud, which at the camera's rate is more than a display needs
or a network carries; and it publishes each map a dozen times over, within
milliseconds, so its own `/octomap_point_cloud_centers` is for the vehicle
only.

`point_cloud_transport` republishes `octomap_cloud` and the map compressed
with Draco on `<cloud>/draco`, for displays over a wireless link: a raw
stereo cloud is a few megabytes a second. It runs only for a vehicle whose
`nav2/` directory has a `draco.yaml`, which sets the quantisation.
"""

import os

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import Command, LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue

CONFIG = "/opt/ovcs/config/nav2.yaml"
OCTOMAP_CONFIG = "/opt/ovcs/config/octomap.yaml"
OCTOMAP_INPUT = "/octomap/cloud_in"
OCTOMAP_OUTPUT = "/octomap/point_cloud_centers"
DRACO_CONFIG = "/opt/ovcs/config/draco.yaml"
URDF = "/opt/ovcs/description/robot.urdf"

NAV_CMD_VEL_RAW = "/cmd_vel_nav_raw"
NAV_CMD_VEL = "/cmd_vel_nav"


# Every server is a lifecycle node; the manager transitions them in
# lifecycle_manager's `node_names` order, which ends with bt_navigator
# because it needs the others' actions to exist before it configures.
SERVERS = [
    ("nav2_controller", "controller_server"),
    ("nav2_planner", "planner_server"),
    ("nav2_behaviors", "behavior_server"),
    ("nav2_bt_navigator", "bt_navigator"),
]


def _draco(name, cloud, use_sim_time):
    """`cloud` republished compressed with Draco on `<cloud>/draco`."""
    return Node(
        package="point_cloud_transport",
        executable="republish",
        name=name,
        output="screen",
        parameters=[
            DRACO_CONFIG,
            use_sim_time,
            {"in_transport": "raw", "out_transport": "draco"},
        ],
        # The plugin names its topic out/draco, not the remapped out's.
        remappings=[("in", cloud), ("out/draco", [cloud, "/draco"])],
    )


def generate_launch_description():
    params = LaunchConfiguration("params_file")
    # A dict overlay wins over the file, which is what lets one file
    # serve wall clock and sim time both.
    use_sim_time = {"use_sim_time": LaunchConfiguration("use_sim_time")}

    octomap = []
    if os.path.exists(OCTOMAP_CONFIG):
        octomap = [
            Node(
                package="topic_tools",
                executable="throttle",
                name="octomap_input_throttle",
                output="screen",
                arguments=[
                    "messages",
                    LaunchConfiguration("octomap_cloud"),
                    LaunchConfiguration("octomap_rate"),
                    OCTOMAP_INPUT,
                ],
                parameters=[use_sim_time],
            ),
            Node(
                package="octomap_server",
                executable="octomap_server_node",
                name="octomap_server",
                output="screen",
                parameters=[OCTOMAP_CONFIG, use_sim_time],
                remappings=[("cloud_in", OCTOMAP_INPUT)],
            ),
            Node(
                package="topic_tools",
                executable="throttle",
                name="octomap_output_throttle",
                output="screen",
                arguments=[
                    "messages",
                    "/octomap_point_cloud_centers",
                    LaunchConfiguration("octomap_rate"),
                    OCTOMAP_OUTPUT,
                ],
                parameters=[use_sim_time],
            ),
        ]

    draco = []
    if os.path.exists(DRACO_CONFIG):
        draco = [
            _draco("point_cloud_draco", LaunchConfiguration("octomap_cloud"), use_sim_time),
            _draco("octomap_draco", OCTOMAP_OUTPUT, use_sim_time),
        ]

    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "params_file",
                default_value=CONFIG,
                description="Nav2 parameter file.",
            ),
            DeclareLaunchArgument(
                "use_sim_time",
                default_value="false",
                description="Overlay the parameter file's clock source; "
                "true only against a simulator publishing /clock.",
            ),
            DeclareLaunchArgument(
                "octomap_cloud",
                default_value="/stereo/points",
                description="The point cloud octomap_server maps, when the vehicle has an octomap.yaml.",
            ),
            DeclareLaunchArgument(
                "octomap_rate",
                default_value="2.0",
                description="Clouds a second octomap_server maps.",
            ),
            DeclareLaunchArgument(
                "robot_state_publisher",
                default_value="true",
                description="Publish the vehicle's URDF; false where something else does.",
            ),
            *octomap,
            *draco,
            Node(
                package="robot_state_publisher",
                executable="robot_state_publisher",
                output="screen",
                condition=IfCondition(LaunchConfiguration("robot_state_publisher")),
                parameters=[
                    # `value_type=str`, or launch parses the XML as YAML.
                    {"robot_description": ParameterValue(Command(["cat ", URDF]), value_type=str)},
                    use_sim_time,
                ],
            ),
            *[
                Node(
                    package=package,
                    executable=executable,
                    name=executable,
                    output="screen",
                    parameters=[params, use_sim_time],
                    # The controller's and the behaviours' velocity goes
                    # to the smoother, never straight to the vehicle —
                    # see the module docstring.
                    remappings=[("/cmd_vel", NAV_CMD_VEL_RAW)],
                )
                for package, executable in SERVERS
            ],
            Node(
                package="nav2_velocity_smoother",
                executable="velocity_smoother",
                name="velocity_smoother",
                output="screen",
                parameters=[params, use_sim_time],
                remappings=[
                    ("/cmd_vel", NAV_CMD_VEL_RAW),
                    ("/cmd_vel_smoothed", NAV_CMD_VEL),
                ],
            ),
            Node(
                package="nav2_lifecycle_manager",
                executable="lifecycle_manager",
                name="lifecycle_manager",
                output="screen",
                parameters=[params, use_sim_time],
            ),
        ]
    )
