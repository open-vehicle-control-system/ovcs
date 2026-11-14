# ROS 2 Lyrical message definitions — provenance

Each `<package>/<Type>.msg` here is the `.msg` file ROS 2 Lyrical installs under `share/<package>/msg/`, byte for byte, including comments and trailing spaces. `definition_test.exs` checks each message module's `msg_definition/0` against its file.

| Packages | Source | Tag |
|---|---|---|
| `std_msgs`, `geometry_msgs`, `sensor_msgs`, `stereo_msgs`, `diagnostic_msgs`, `visualization_msgs` | [ros2/common_interfaces](https://github.com/ros2/common_interfaces) | `5.9.4` |
| `builtin_interfaces`, `rosgraph_msgs` | [ros2/rcl_interfaces](https://github.com/ros2/rcl_interfaces) | `2.4.5` |
| `tf2_msgs` | [ros2/geometry2](https://github.com/ros2/geometry2) | `0.45.10` |
| `vision_msgs` | [ros-perception/vision_msgs](https://github.com/ros-perception/vision_msgs) | `4.2.0` |
| `foxglove_msgs` | [foxglove/foxglove-sdk](https://github.com/foxglove/foxglove-sdk), `ros/src/foxglove_msgs/ros2/` | `ros-v3.6.3` |

The tags are the versions the Lyrical distribution file of [ros/rosdistro](https://github.com/ros/rosdistro/blob/master/lyrical/distribution.yaml) releases. `foxglove_msgs` installs its `ros2/*.msg` unchanged as `msg/*.msg`.

Each file was fetched from `https://raw.githubusercontent.com/<repository>/<tag>/<path>`, for example `https://raw.githubusercontent.com/ros2/common_interfaces/5.9.4/std_msgs/msg/Header.msg`. To add a type, fetch its file the same way, with every type it names that is not here yet.
