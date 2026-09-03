#!/usr/bin/env bash
#
# Bring up the simulator and the real perception pipeline, check what it
# reports against the world, tear it all down. One command, exit code
# says whether perception is still correct.
#
# This exists because verifying it by hand takes about fifteen steps and
# two environment variables that are easy to get wrong — and getting
# either wrong fails in a way that looks like something else:
#
#   * run from bridges/ros_bridge instead of bridges/firmware and
#     Cantastic dies with "CAN network mappings are missing", because
#     the library has no config/ of its own.
#   * omit BRIDGE_FIRMWARE_ID and firmware_id/0 falls back to "ros",
#     which starts the joy/IMU wiring instead of the stereo pipeline
#     and publishes no stereo topics at all, silently.
#
# Usage:
#   ./verify_perception.sh              # stereo only
#   OVCS_DETECTOR=stub ./verify_perception.sh    # + the fusion check
#   KEEP_UP=1 ./verify_perception.sh    # leave it running to poke at
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BASE="$REPO/ros2/base"
PERCEPTION_LOG="${TMPDIR:-/tmp}/ovcs-verify-perception.log"

DETECTOR="${OVCS_DETECTOR:-off}"
KEEP_UP="${KEEP_UP:-0}"
beam_pid=""

log()  { printf '\n\033[1;36m▸\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; }

cleanup() {
  local code=$?
  if [ "$KEEP_UP" = "1" ]; then
    log "KEEP_UP=1 — leaving the stack running"
    printf '  perception log: %s\n' "$PERCEPTION_LOG"
    printf '  stop with: (cd %s && docker compose down) && (cd %s && docker compose rm -sf ros2 zenohd)\n' \
      "$HERE" "$BASE"
    return $code
  fi
  log "Tearing down"
  # The BEAM first: it holds a Zenoh session to the router.
  [ -n "$beam_pid" ] && kill "$beam_pid" 2>/dev/null && sleep 2
  (cd "$HERE" && timeout 120 docker compose down >/dev/null 2>&1)
  (cd "$BASE" && timeout 120 docker compose rm -sf ros2 zenohd >/dev/null 2>&1)
  return $code
}
trap cleanup EXIT

# ── preflight ────────────────────────────────────────────────────────
# vcan0 needs root to create, so this checks rather than tries: failing
# here with the command to run beats failing later inside Cantastic.
if ! ip link show vcan0 >/dev/null 2>&1; then
  fail "vcan0 does not exist — Cantastic will not start without it."
  fail "Run:  ./ovcs can setup ovcs_mini"
  exit 1
fi

# ── up ──────────────────────────────────────────────────────────────
log "Starting the Zenoh router"
(cd "$BASE" && ZENOH_ENDPOINT_IP=127.0.0.1 timeout 180 docker compose \
  --profile standalone up -d zenohd ros2) || { fail "router/ros2 failed to start"; exit 1; }

log "Starting the simulator (workshop.sdf — textured, so SGBM has something to correlate)"
(cd "$HERE" && timeout 300 docker compose up -d) || { fail "sim failed to start"; exit 1; }

log "Starting the perception bridge (OVCS_DETECTOR=$DETECTOR)"
(
  cd "$REPO/bridges/firmware" || exit 1
  VEHICLE=OvcsMini \
  OVCS_SIM=1 \
  OVCS_DETECTOR="$DETECTOR" \
  ZENOH_ENDPOINT_IP=127.0.0.1 \
  BRIDGE_FIRMWARE_ID=ros_perception \
  CAN_NETWORK_MAPPINGS=ovcs:vcan0 \
  exec mise exec -- mix run --no-halt
) > "$PERCEPTION_LOG" 2>&1 &
beam_pid=$!

# A crash here is silent otherwise: the pipeline dies and the checks
# just report "nothing published", which reads like a sim problem.
sleep 25
if ! kill -0 "$beam_pid" 2>/dev/null; then
  fail "the perception bridge exited during startup:"
  tail -25 "$PERCEPTION_LOG" >&2
  exit 1
fi

# ── check ───────────────────────────────────────────────────────────
log "Checking perception against the world"
# Piped over stdin rather than run from a mount: scripts/ is mounted
# into the *sim* container, while the checks need vision_msgs, which
# lives in the base station's ros2 image. Piping avoids adding a mount
# to a compose file for the sake of one script.
(cd "$BASE" && timeout 300 docker compose exec -T ros2 bash -lc \
  'source /opt/ros/*/setup.bash 2>/dev/null; exec python3 -') \
  < "$HERE/scripts/perception_test.py"
result=$?

if [ "$result" -ne 0 ]; then
  fail "perception checks failed — last of the bridge log:"
  tail -20 "$PERCEPTION_LOG" >&2
fi

exit "$result"
