#!/usr/bin/env bash
#
# The full planner path with no vehicle and no simulator: Nav2 (the
# exact image the car runs) plans against odometry dead-reckoned by
# the host ros_bridge from a host VMS's vehicle_motion frame, and its
# velocity commands come back down through the bridge onto the CAN
# bus as 0x2B1. One command, exit code says whether the loop closes.
#
# What the simulator cannot prove and this does: the VMS-side
# conversion path exists end to end. Gazebo's loop feeds Nav2's
# TwistStamped straight into its own Ackermann plugin, bypassing the
# bridge, the CAN frames and the VMS entirely. Here every hop is the
# vehicle's own code; only the physics is missing, so the vehicle
# never moves and never arrives. The assertions are about what flows,
# not where it gets to:
#
#   /odom is published            (VMS 0x60B -> bridge dead reckoning)
#   Nav2 finishes lifecycle bringup (its costmaps accepted the tf)
#   0x2B1 carries a command        (Nav2 -> Zenoh -> bridge -> CAN)
#
# Needs: the ovcs CLI built (mise run cli), vcan support, docker,
# can-utils. Run from anywhere.
#
# Usage:
#   ./verify_planner_loop.sh              # up, check, down
#   KEEP_UP=1 ./verify_planner_loop.sh    # leave it running to poke at
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

KEEP_UP="${KEEP_UP:-0}"
RUN_PID=""
CANGEN_PID=""

log()  { printf '\n\033[1;36m▸\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; }

cleanup() {
  local code=$?
  if [ "$KEEP_UP" = "1" ]; then
    log "KEEP_UP=1 — leaving the stack running"
    printf '  nav2 log:  docker logs ovcs-nav2-vehicle\n'
    printf '  vehicle:   kill %s\n' "${RUN_PID:-<gone>}"
    printf '  stop with: (cd %s && docker compose --profile nav2 --profile standalone down)\n' "$HERE"
    return $code
  fi
  log "Tearing down"
  [ -n "$CANGEN_PID" ] && kill "$CANGEN_PID" >/dev/null 2>&1
  # ./ovcs run supervises its BEAMs; killing its process group takes
  # them all down with it.
  [ -n "$RUN_PID" ] && kill -- -"$RUN_PID" >/dev/null 2>&1
  (cd "$HERE" && timeout 120 docker compose --profile nav2 --profile standalone down >/dev/null 2>&1)
  return $code
}
trap cleanup EXIT

command -v candump >/dev/null || { fail "can-utils not installed"; exit 1; }
[ -x "$REPO/cli/ovcs" ] || { fail "ovcs CLI not built — run: mise run cli"; exit 1; }

# ── up ──────────────────────────────────────────────────────────────
log "Provisioning vcan"
(cd "$REPO" && ./cli/ovcs can setup ovcs_mini) || { fail "vcan setup failed"; exit 1; }

log "Starting the Zenoh router and the vehicle's Nav2 image"
(cd "$HERE" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 600 docker compose \
  --profile standalone --profile nav2 up -d zenohd ros2 nav2) \
  || { fail "router/nav2 failed to start"; exit 1; }

log "Starting the host vehicle (VMS + bridges)"
(cd "$REPO" && setsid ./cli/ovcs run ovcs_mini >/tmp/ovcs-planner-loop-run.log 2>&1) &
RUN_PID=$!

log "Synthesising the controller: zero-speed pulse counter stream"
# The VMS needs 0x709 alive to know the speed at all; a count and
# frequency of zero is a stationary vehicle. Same stream as the host
# bench recipe in docs/vehicle_parameterisation.md.
cangen vcan0 -I 709 -L 4 -D 00000000 -g 10 >/dev/null 2>&1 &
CANGEN_PID=$!

log "Waiting for the VMS's vehicle_motion frame (0x60B)"
if ! timeout 120 candump -n 1 vcan0,60B:7FF >/dev/null; then
  fail "no 0x60B within 120 s — VMS not up? see /tmp/ovcs-planner-loop-run.log"
  exit 1
fi

log "Walking the control level to :ros/:autonomous"
# Sticks centred; level :manual -> :radio -> :ros, then the commander
# to :autonomous. Every step needs the standstill the stream provides.
cansend vcan0 2A0#DC05DC0500000000
sleep 1; cansend vcan0 2A1#E803DC0500000000
sleep 1; cansend vcan0 2A1#E803D00700000000
sleep 1; cansend vcan0 2A1#D007D00700000000

log "Waiting for /odom on the fabric"
if ! (cd "$HERE" && timeout 120 docker compose exec -T ros2 bash -lc \
  'ros2 topic echo --once /odom nav_msgs/msg/Odometry >/dev/null 2>&1'); then
  fail "/odom never appeared — bridge odometry not publishing"
  exit 1
fi

log "Waiting for Nav2 lifecycle bringup"
ok=0
for _ in $(seq 1 24); do
  if docker logs ovcs-nav2-vehicle 2>&1 | grep -q "Managed nodes are active"; then
    ok=1; break
  fi
  sleep 5
done
if [ "$ok" -ne 1 ]; then
  fail "Nav2 did not finish lifecycle bringup:"
  docker logs ovcs-nav2-vehicle 2>&1 | grep -iE "FATAL|ERROR" | tail -15 >&2
  exit 1
fi

# ── check ───────────────────────────────────────────────────────────
log "Sending a goal 2 m ahead"
(timeout 60 docker exec ovcs-nav2-vehicle bash -lc \
  'source /opt/ros/lyrical/setup.bash 2>/dev/null;
   ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose \
     "{pose: {header: {frame_id: odom}, pose: {position: {x: 2.0}, orientation: {w: 1.0}}}}" \
     >/dev/null 2>&1') &

log "Asserting a velocity command reaches the CAN bus (0x2B1, nonzero)"
frames=$(timeout 60 candump -n 200 vcan0,2B1:7FF 2>/dev/null)
if [ -z "$frames" ]; then
  fail "no 0x2B1 on the bus — the bridge is not emitting"
  exit 1
fi
# candump prints "vcan0  2B1  [8]  <byte> x8"; linear and angular are
# the first four bytes. All-zero on every frame means the bridge is
# alive but Nav2 never commanded motion.
if ! printf '%s\n' "$frames" \
  | awk '{ if ($4 $5 $6 $7 != "00000000") found = 1 } END { exit !found }'; then
  fail "0x2B1 flows but every command is zero — Nav2 commanded nothing"
  exit 1
fi

log "The loop closes: goal -> Nav2 -> Zenoh -> bridge -> 0x2B1"
exit 0
