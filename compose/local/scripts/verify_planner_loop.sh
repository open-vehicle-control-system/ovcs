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
LOCAL="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

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
    printf '  stop with: (cd %s && docker compose -f base.yml --profile nav2 --profile standalone down)\n' "$LOCAL"
    return $code
  fi
  log "Tearing down"
  [ -n "$CANGEN_PID" ] && kill "$CANGEN_PID" >/dev/null 2>&1
  # ./ovcs run supervises its BEAMs; killing its process group takes
  # them all down with it.
  [ -n "$RUN_PID" ] && kill -- -"$RUN_PID" >/dev/null 2>&1
  (cd "$LOCAL" && timeout 120 docker compose -f base.yml --profile nav2 --profile standalone down >/dev/null 2>&1)
  return $code
}
trap cleanup EXIT

command -v candump >/dev/null || { fail "can-utils not installed"; exit 1; }
[ -x "$REPO/cli/ovcs" ] || { fail "ovcs CLI not built — run: mise run cli"; exit 1; }

# ── up ──────────────────────────────────────────────────────────────
log "Provisioning vcan"
(cd "$REPO" && ./cli/ovcs can setup ovcs_mini) || { fail "vcan setup failed"; exit 1; }

# Nav2 is started last, on purpose. Its costmap waits for the
# odom -> base_link transform during lifecycle activation and
# lifecycle_manager does not retry a timed-out activation: if Nav2
# comes up before odometry, it fails to activate and sits inactive
# for good. On the vehicle the same race exists — the always-on Nav2
# container against a VMS that must boot its CAN stack first — so
# bringing odometry up before the planner is the real ordering, not
# a test convenience. Here the router build can take a while, so it
# is pulled/built up front (nav2 image) but the container is not run
# until /odom and /tf are live.
log "Starting the Zenoh router, and building the vehicle's Nav2 image"
(cd "$LOCAL" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 600 docker compose -f base.yml \
  --profile standalone up -d zenohd ros2) \
  || { fail "router failed to start"; exit 1; }
(cd "$LOCAL" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 600 docker compose -f base.yml \
  --profile nav2 build nav2) \
  || { fail "nav2 image failed to build"; exit 1; }

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
# A fresh `ros2` invocation has to bring up a Zenoh session and
# discover the bridge's publishers by liveliness token; the first
# single-shot echo can return before that converges. Poll rather than
# trust one shot, and let echo resolve the type itself — an explicit
# type errors out instead of waiting when the topic is not yet in the
# daemon's graph.
odom_seen=0
for _ in $(seq 1 20); do
  if (cd "$LOCAL" && timeout 20 docker compose -f base.yml exec -T ros2 bash -lc \
    'source /opt/ros/lyrical/setup.bash 2>/dev/null; timeout 8 ros2 topic echo --once /odom >/dev/null 2>&1'); then
    odom_seen=1; break
  fi
  sleep 3
done
if [ "$odom_seen" -ne 1 ]; then
  fail "/odom never appeared — bridge odometry not publishing"
  exit 1
fi

log "Confirming the odom -> base_link transform is on /tf"
# The message alone is not enough: Nav2's costmap resolves poses
# through the tf tree, so a /odom with no matching /tf activates
# nothing. This is the transform Nav2 will wait for.
if ! (cd "$LOCAL" && timeout 20 docker compose -f base.yml exec -T ros2 bash -lc \
  'source /opt/ros/lyrical/setup.bash 2>/dev/null;
   timeout 8 ros2 topic echo --once /tf 2>/dev/null | grep -q "child_frame_id: base_link"'); then
  fail "/tf carries no odom -> base_link transform"
  exit 1
fi

log "Starting Nav2 now that odometry is live"
(cd "$LOCAL" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 300 docker compose -f base.yml \
  --profile nav2 up -d nav2) \
  || { fail "nav2 failed to start"; exit 1; }

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
# The path splits into two claims, asserted separately because one
# combined "goal -> nonzero 0x2B1" capture is not deterministic on a
# bench: odom never advances (nothing moves), so Nav2's progress
# checker aborts the goal within seconds and the controller falls
# back to zero. The nonzero window is real but racy, so instead:
#
#   Leg A (planner):  a goal makes Nav2 publish nonzero on /cmd_vel_nav
#   Leg B (bridge):   a nonzero /cmd_vel_nav becomes nonzero 0x2B1
#
# Together they are the whole path, each leg deterministic.

log "Leg A: a goal makes Nav2 command a nonzero velocity on /cmd_vel_nav"
(timeout 30 docker exec ovcs-nav2-vehicle bash -lc \
  'source /opt/ros/lyrical/setup.bash 2>/dev/null;
   ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose \
     "{pose: {header: {frame_id: odom}, pose: {position: {x: 5.0}, orientation: {w: 1.0}}}}" \
     >/dev/null 2>&1') &
sleep 2
nav_cmd=0
for _ in $(seq 1 8); do
  x=$(cd "$LOCAL" && timeout 12 docker compose -f base.yml exec -T ros2 bash -lc \
    'source /opt/ros/lyrical/setup.bash 2>/dev/null;
     timeout 6 ros2 topic echo --once --field twist.linear.x /cmd_vel_nav 2>/dev/null' \
    | head -1 | tr -d '[:space:]')
  case "$x" in ""|0.0|-0.0|0) : ;; *) nav_cmd=1; break ;; esac
  sleep 1
done
if [ "$nav_cmd" -ne 1 ]; then
  fail "Nav2 never commanded a nonzero velocity on /cmd_vel_nav"
  docker logs ovcs-nav2-vehicle 2>&1 | grep -iE "reject|abort|fail" | tail -8 >&2
  exit 1
fi

log "Leg B: a nonzero /cmd_vel_nav reaches the CAN bus as nonzero 0x2B1"
# Driven directly rather than through Nav2, so the assertion does not
# depend on the progress checker leaving a command up long enough to
# sample. This is the bridge's own conversion, the hop Gazebo bypasses.
(cd "$LOCAL" && timeout 15 docker compose -f base.yml exec -T ros2 bash -lc \
  'source /opt/ros/lyrical/setup.bash 2>/dev/null;
   ros2 topic pub -r 10 /cmd_vel_nav geometry_msgs/msg/TwistStamped \
     "{header: {frame_id: base_link}, twist: {linear: {x: 0.5}, angular: {z: 0.3}}}" \
     >/dev/null 2>&1') &
sleep 2
frames=$(timeout 12 candump -n 60 vcan0,2B1:7FF 2>/dev/null)
if [ -z "$frames" ]; then
  fail "no 0x2B1 on the bus — the velocity consumer is not emitting"
  exit 1
fi
# candump prints "vcan0  2B1  [5]  <byte>..."; linear and angular are
# the first four data bytes. All-zero everywhere means the consumer
# received nothing or dropped it.
if ! printf '%s\n' "$frames" \
  | awk '{ if ($4 $5 $6 $7 != "00000000") found = 1 } END { exit !found }'; then
  fail "0x2B1 flows but stays zero — the velocity consumer is not converting /cmd_vel_nav"
  exit 1
fi

log "The loop closes: goal -> Nav2 -> /cmd_vel_nav -> Zenoh -> bridge -> 0x2B1"
exit 0
