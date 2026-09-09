#!/usr/bin/env bash
# CMD for the joy image. Reads a USB game controller from ${JOY_DEV}
# (bind-mounted from the host's /dev/input) and publishes
# `sensor_msgs/Joy` on /joy via `joy_linux/joy_node`. Runs under the
# shared entrypoint, which has already prepared Zenoh + sourced the
# ROS overlay.

set -euo pipefail

: "${JOY_DEV:=/dev/input/js0}"
: "${JOY_DEADZONE:=0.05}"
: "${JOY_AUTOREPEAT_RATE:=20.0}"

if [ ! -e "${JOY_DEV}" ]; then
  echo "joy: ${JOY_DEV} not present on host — plug the controller in" >&2
  echo "joy: available devices: $(ls /dev/input/js* 2>/dev/null || echo none)" >&2
  exit 1
fi

echo "joy: reading ${JOY_DEV}, peering with ${ZENOH_ENDPOINT_IP}:7447"

exec ros2 run joy_linux joy_linux_node \
  --ros-args \
  -p dev:="${JOY_DEV}" \
  -p deadzone:="${JOY_DEADZONE}" \
  -p autorepeat_rate:="${JOY_AUTOREPEAT_RATE}"
