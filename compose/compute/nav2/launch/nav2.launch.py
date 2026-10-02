"""Map-based Ackermann navigation with a guarded velocity output."""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

CONFIG = "/opt/ovcs/config/nav2.yaml"

NAV_CMD_VEL_RAW = "/cmd_vel_nav_raw"
NAV_CMD_VEL = "/cmd_vel_nav_smoothed"


# Every server is a lifecycle node; the manager transitions them in
# lifecycle_manager's `node_names` order, which ends with bt_navigator
# because it needs the others' actions to exist before it configures.
SERVERS = [
    ("nav2_controller", "controller_server"),
    ("nav2_planner", "planner_server"),
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
                    # The controller feeds the smoother before the independent guard.
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
            ExecuteProcess(
                cmd=[
                    "python3",
                    "/opt/ovcs/forward_explore/motion_guard.py",
                    "--ros-args",
                    "--params-file",
                    params,
                    "-p",
                    ["use_sim_time:=", LaunchConfiguration("use_sim_time")],
                ],
                output="screen",
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
