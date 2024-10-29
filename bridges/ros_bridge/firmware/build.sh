#!/bin/bash
export MIX_TARGET=ovcs_rosbridge_system_rpi4
export ROS_DISTRO=humble

BASEDIR=$(dirname $0)

cd $BASEDIR/../firmware
mix deps.get
mix firmware