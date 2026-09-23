"""Nav2 for the OVCS Mini — launched identically on the vehicle, on a
dev machine, and against the simulator.

One parameter file (`config/nav2.yaml`, the vehicle's truth) and one
switch: `use_sim_time:=true` overlays the file for a simulated run,
because a params fork would drift and stop the simulator being
evidence about the vehicle.

Four lifecycle servers and a velocity smoother, plus a manager to
bring them up. Deliberately *not* `nav2_bringup`: there is no such
package in the Lyrical archive, and its launch file would pull in
map_server and AMCL, neither of which this configuration uses. See
`config/nav2.yaml` for why there is no map.

The velocity output needs saying out loud, because it is the one thing
that silently does nothing if it is wrong. Nav2 1.5.1 publishes
`geometry_msgs/TwistStamped`, not `Twist` —
`nav2_util::TwistPublisher` reads `enable_stamped_cmd_vel` with a
default of **true**, and `controller_server::publishVelocity` takes a
`TwistStamped`. (The doc comment in `twist_publisher.hpp` still claims
unstamped is the default; the code disagrees, and the code wins.)

So Nav2's final output is `/cmd_vel_nav`, and `sim.launch.py`
bridges that as `TwistStamped` alongside the existing unstamped
`/cmd_vel` that teleop and `drive_test.py` use. Two separate bridge
nodes, both feeding the same Gazebo topic: one `parameter_bridge`
cannot map two ROS topics onto one Gazebo topic, and one topic cannot
carry two ROS types.

That split mirrors the vehicle's own CAN protocol, where a joystick
and a planner arrive on two different frames (`0x2B0` actuator
command, `0x2B1` velocity command). On the vehicle the control level
manager arbitrates between them; nothing does here — run one or the
other.

The controller and the behaviours do not publish `/cmd_vel_nav`
themselves: they publish `/cmd_vel_nav_raw`, and the velocity smoother
republishes it on `/cmd_vel_nav` with its limits and deadband applied.
The deadband keeps every non-zero linear velocity at or above the
vehicle's slowest drivable speed; see `config/nav2.yaml`.
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

CONFIG = "/opt/ovcs/config/nav2.yaml"

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


def generate_launch_description():
    params = LaunchConfiguration("params_file")
    # A dict overlay wins over the file, which is what lets one file
    # serve wall clock and sim time both.
    use_sim_time = {"use_sim_time": LaunchConfiguration("use_sim_time")}

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
