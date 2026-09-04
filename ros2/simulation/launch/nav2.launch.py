"""Nav2 for the simulated OVCS Mini.

Four lifecycle servers plus a manager to bring them up. Deliberately
*not* `nav2_bringup`: there is no such package in the Lyrical archive,
and its launch file would pull in map_server and AMCL, neither of which
this configuration uses. See `config/nav2.yaml` for why there is no map.

The velocity output needs saying out loud, because it is the one thing
that silently does nothing if it is wrong. Nav2 1.5.1 publishes
`geometry_msgs/TwistStamped`, not `Twist` —
`nav2_util::TwistPublisher` reads `enable_stamped_cmd_vel` with a
default of **true**, and `controller_server::publishVelocity` takes a
`TwistStamped`. (The doc comment in `twist_publisher.hpp` still claims
unstamped is the default; the code disagrees, and the code wins.)

So the controller publishes to `/cmd_vel_nav`, and `sim.launch.py`
bridges that as `TwistStamped` alongside the existing unstamped
`/cmd_vel` that teleop and `drive_test.py` use. Two separate bridge
nodes, both feeding the same Gazebo topic: one `parameter_bridge`
cannot map two ROS topics onto one Gazebo topic, and one topic cannot
carry two ROS types.

That split mirrors the vehicle's own CAN protocol, where `0x2B0`
carries `control_level: joy | auto`. Nothing arbitrates between them
here, exactly as nothing arbitrates on OVCS Mini today — run one or
the other.
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

CONFIG = "/opt/ovcs/config/nav2.yaml"

# Every server is a lifecycle node; the manager transitions them in this
# order. bt_navigator last, because it needs the others' actions to
# exist before it configures.
SERVERS = [
    ("nav2_controller", "controller_server"),
    ("nav2_planner", "planner_server"),
    ("nav2_behaviors", "behavior_server"),
    ("nav2_bt_navigator", "bt_navigator"),
]


def generate_launch_description():
    params = LaunchConfiguration("params_file")

    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "params_file",
                default_value=CONFIG,
                description="Nav2 parameter file.",
            ),
            *[
                Node(
                    package=package,
                    executable=executable,
                    name=executable,
                    output="screen",
                    parameters=[params],
                    # The controller's velocity goes to its own topic so
                    # the unstamped teleop path keeps working — see the
                    # module docstring.
                    remappings=[("/cmd_vel", "/cmd_vel_nav")],
                )
                for package, executable in SERVERS
            ],
            Node(
                package="nav2_lifecycle_manager",
                executable="lifecycle_manager",
                name="lifecycle_manager",
                output="screen",
                parameters=[params],
            ),
        ]
    )
