#!/usr/bin/env bash
# CMD for the foxglove_bridge image. Launches the ROS 2 → WebSocket
# bridge so Foxglove Studio can attach over the same Zenoh fabric.
# Runs under the shared entrypoint, which has already prepared Zenoh
# + sourced the ROS overlay.

set -euo pipefail

: "${FOXGLOVE_BRIDGE_PORT:=8765}"
: "${FOXGLOVE_BRIDGE_INTERNAL_PORT:=8766}"
: "${FOXGLOVE_MESSAGE_BACKLOG_SIZE:=32}"

# Bound stale data waiting for a slow WebSocket client. The SDK drops
# the oldest data message when this per-client queue is full.

echo "foxglove_bridge: listening on ws://0.0.0.0:${FOXGLOVE_BRIDGE_PORT}, peering with ${ZENOH_ENDPOINT_IP}:7447"

bridge_executable="$(ros2 pkg prefix foxglove_bridge)/lib/foxglove_bridge/foxglove_bridge"
child_pids=()
cleanup() {
  trap - EXIT INT TERM
  if ((${#child_pids[@]})); then
    kill "${child_pids[@]}" 2>/dev/null || true
    wait "${child_pids[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM

"${bridge_executable}" \
  --ros-args \
  -p port:="${FOXGLOVE_BRIDGE_INTERNAL_PORT}" \
  -p address:=127.0.0.1 \
  -p message_backlog_size:="${FOXGLOVE_MESSAGE_BACKLOG_SIZE}" &
child_pids+=("$!")

python3 /usr/local/bin/foxglove_compression \
  --port "${FOXGLOVE_BRIDGE_PORT}" \
  --upstream-port "${FOXGLOVE_BRIDGE_INTERNAL_PORT}" &
child_pids+=("$!")

# A failed child must restart the whole service, not leave a half-working relay.
status=0
wait -n "${child_pids[@]}" || status=$?
if ((status == 0)); then
  status=1
fi
exit "${status}"
