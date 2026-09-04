#!/usr/bin/env bash
#
# Bring up the simulator, drive it, check the odometry against the
# geometry the model claims, tear it all down. One command, exit code
# says whether the drivetrain is still correct.
#
# The sibling of verify_perception.sh, and much smaller, because this
# loop never leaves ROS: sim → /odom → drive_test.py. No CAN, no BEAM,
# no detector — so none of the preflight that verify_perception.sh
# needs applies here.
#
# It exists for one bug class: the model's wheel radius was once wrong
# by 2x, which reports 2x the distance travelled while looking
# perfectly fine on screen. Nothing catches that but driving and
# measuring.
#
# Usage:
#   ./verify_drivetrain.sh              # up, check, down
#   KEEP_UP=1 ./verify_drivetrain.sh    # leave it running to poke at
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
    printf '  stop with: (cd %s && docker compose down) && (cd %s && docker compose rm -sf ros2 zenohd)\n' \
      "$HERE" "$BASE"
    return $code
  fi
  log "Tearing down"
  (cd "$HERE" && timeout 120 docker compose down >/dev/null 2>&1)
  (cd "$BASE" && timeout 120 docker compose rm -sf ros2 zenohd >/dev/null 2>&1)
  return $code
}
trap cleanup EXIT

# ── up ──────────────────────────────────────────────────────────────
log "Starting the Zenoh router"
(cd "$BASE" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 180 docker compose \
  --profile standalone up -d zenohd ros2) || { fail "router/ros2 failed to start"; exit 1; }

# empty.sdf would do — nothing here needs texture to correlate against,
# unlike the perception check — but sharing workshop.sdf keeps the two
# verifiers on one world, so a model change is exercised the same way
# by both.
log "Starting the simulator"
(cd "$HERE" && timeout 300 docker compose up -d) || { fail "sim failed to start"; exit 1; }

# ros2_control needs to have claimed the joints and started publishing
# /odom before the first command means anything.
sleep 20

# ── check ───────────────────────────────────────────────────────────
log "Driving the vehicle and measuring what odometry reports"
# Piped over stdin rather than run from the mount, matching
# verify_perception.sh: scripts/ is mounted into the *sim* container,
# but the checks want the base station's rclpy so they talk to the
# same Zenoh router everything else does.
(cd "$BASE" && timeout 300 docker compose exec -T ros2 bash -lc \
  'source /opt/ros/*/setup.bash 2>/dev/null; exec python3 -') \
  < "$HERE/scripts/drive_test.py"
result=$?

[ "$result" -ne 0 ] && fail "drivetrain checks failed"

exit "$result"
