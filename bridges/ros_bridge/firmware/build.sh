#!/bin/bash
export MIX_TARGET=ovcs_bridges_system_rpi5
export ROS_DISTRO=jazzy
# export ROS_ARCH=arm64v8
# export ZENOH_ENDPOINT_IP=172.16.0.63

# unset ROS_DIR
# unset ROS_INSTALL_FROM_SOURCE

mix deps.get
# echo "Prepare ROS2 resources"
# mix rclex.prep.ros2 --arch arm64v8
# echo "Generate ROS2 messages"
# mix rclex.gen.msgs
echo "Firmware"
mix firmware
