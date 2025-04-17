#!/bin/bash
export MIX_TARGET=ovcs_rosbridge_system_rpi4
export ROS_DISTRO=humble
export ROS_ARCH=arm64v8

rm -rf rootfs_overlay/opt/ros
mix deps.get
echo "Prepare ROS2 resources"
./deps/rclex/scripts/prepare_ros2_resources.exs
mkdir -p rootfs_overlay/opt/ros/$ROS_DISTRO
cp -r deps/rclex/.ros2/$ROS_ARCH/opt/ros/$ROS_DISTRO/* rootfs_overlay/opt/ros/$ROS_DISTRO
echo "Generate ROS2 messages"
mix rclex.gen.msgs
echo "Firmware"
mix firmware
