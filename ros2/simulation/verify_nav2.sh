#!/usr/bin/env bash
#
# Bring up the simulator and Nav2, send a goal, check what Nav2
# commanded, tear it all down. One command, exit code says whether Nav2
# can still drive an Ackermann vehicle.
#
# The third sibling of verify_perception.sh and verify_drivetrain.sh.
# Slower than both, because it waits for Nav2's lifecycle bringup and
# then for the vehicle to actually drive somewhere.
#
# What it is really for is the turning-radius check. Nav2 reaching a
# goal in simulation proves less than it appears to: Gazebo's
# AckermannSteering quietly ignores commands it cannot execute, so a
# configuration that has reverted to the holonomic default still
# arrives. See scripts/nav2_test.py.
#
# Usage:
#   ./verify_nav2.sh              # up, navigate, check, down
#   KEEP_UP=1 ./verify_nav2.sh    # leave it running to poke at
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BASE="$REPO/ros2/base"

KEEP_UP="${KEEP_UP:-0}"

log()  { printf '\n\033[1;36m▸\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; }

cleanup() {
  local code=$?
  if [ "$KEEP_UP" = "1" ]; then
    log "KEEP_UP=1 — leaving the stack running"
    printf '  nav2 log: docker logs ovcs-nav2\n'
    printf '  stop with: (cd %s && docker compose --profile nav2 down) && (cd %s && docker compose rm -sf ros2 zenohd)\n' \
      "$HERE" "$BASE"
    return $code
  fi
  log "Tearing down"
  (cd "$HERE" && timeout 120 docker compose --profile nav2 down >/dev/null 2>&1)
  (cd "$BASE" && timeout 120 docker compose rm -sf ros2 zenohd >/dev/null 2>&1)
  return $code
}
trap cleanup EXIT

# ── up ──────────────────────────────────────────────────────────────
log "Starting the Zenoh router"
(cd "$BASE" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 180 docker compose \
  --profile standalone up -d zenohd ros2) || { fail "router/ros2 failed to start"; exit 1; }

log "Starting the simulator"
(cd "$HERE" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 300 docker compose up -d) \
  || { fail "sim failed to start"; exit 1; }

# ros2_control has to have claimed the joints and be publishing /odom
# and /tf before Nav2's costmaps will accept a transform.
sleep 20

log "Starting Nav2"
(cd "$HERE" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 300 docker compose --profile nav2 up -d nav2) \
  || { fail "nav2 failed to start"; exit 1; }

# Lifecycle bringup is sequential across five nodes and each waits on
# a transform. A failure here is otherwise reported as "the action
# server never appeared", which reads like a discovery problem.
sleep 30
if ! docker logs ovcs-nav2 2>&1 | grep -q "Managed nodes are active"; then
  fail "Nav2 did not finish lifecycle bringup:"
  docker logs ovcs-nav2 2>&1 | grep -iE "FATAL|ERROR" | tail -15 >&2
  exit 1
fi

# ── check ───────────────────────────────────────────────────────────
log "Navigating to a goal and checking what Nav2 commanded"
# Run inside the nav2 container, not the base station's: the checks
# need nav2_msgs for the NavigateToPose action, which only this image
# has. Piped over stdin for the same reason as the other two verifiers
# — scripts/ is mounted into the *sim* container.
(timeout 300 docker exec -i ovcs-nav2 bash -lc \
  'source /opt/ros/lyrical/setup.bash 2>/dev/null; exec python3 -') \
  < "$HERE/scripts/nav2_test.py"
result=$?

if [ "$result" -ne 0 ]; then
  fail "Nav2 checks failed — last of the nav2 log:"
  docker logs ovcs-nav2 2>&1 | tail -20 >&2
fi

exit "$result"
