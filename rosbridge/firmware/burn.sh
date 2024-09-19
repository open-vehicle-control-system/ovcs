#!/bin/bash
export MIX_TARGET=ovcs_vms_system_rpi4
export ROS_DISTRO=humble
export ROS_DIR=/opt/ros/humble

BASEDIR=$(dirname $0)

cd $BASEDIR/firmware

mix deps.get
mix burn