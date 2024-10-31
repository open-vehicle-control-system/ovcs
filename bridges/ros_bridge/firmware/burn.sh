#!/bin/bash
export MIX_TARGET=ovcs_rosbridge_system_rpi4
export ROS_DISTRO=humble
export ROS_ARCH=arm64v8

BASEDIR=$(dirname $0)

cd $BASEDIR/../firmware
mix burn