#!/usr/bin/env bash
# CMD for the foxglove_bridge image. Launches the ROS 2 → WebSocket
# bridge so Foxglove Studio can attach over the same Zenoh fabric.
# Runs under the shared entrypoint, which has already prepared Zenoh
# + sourced the ROS overlay.

set -euo pipefail

: "${FOXGLOVE_BRIDGE_PORT:=8765}"

echo "foxglove_bridge: listening on ws://0.0.0.0:${FOXGLOVE_BRIDGE_PORT}, peering with ${ZENOH_ENDPOINT_IP}:7447"

exec ros2 run foxglove_bridge foxglove_bridge \
  --ros-args \
  -p port:="${FOXGLOVE_BRIDGE_PORT}" \
  -p address:=0.0.0.0
