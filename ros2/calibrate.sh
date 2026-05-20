#!/usr/bin/env bash
# Host-side launcher for the dockerized stereo calibrator. Handles
# X authorization, exports the chessboard parameters, and runs the
# `calibrator` compose service (which itself runs
# `docker/calibrator.sh` inside the container).
#
# Prerequisites:
#   - `./ovcs run ovcs_mini` already streaming both cameras
#   - X server reachable (Xorg or XWayland)
#
# Usage:
#   ros2/calibrate.sh                           # 8x5 inner corners, 30 mm squares
#   ros2/calibrate.sh 9x6                       # override corner count
#   ros2/calibrate.sh 8x5 0.025                 # override corners + square size
#
# Environment overrides (take precedence over positional args):
#   CHESSBOARD_INNER_CORNERS=8x5
#   CHESSBOARD_SQUARE_M=0.030
#   APPROXIMATE_SYNC=0.05
#   DISPLAY=:0

set -euo pipefail

cd "$(dirname "$0")"

corners="${CHESSBOARD_INNER_CORNERS:-${1:-8x5}}"
square="${CHESSBOARD_SQUARE_M:-${2:-0.030}}"
approx_sync="${APPROXIMATE_SYNC:-0.05}"
display="${DISPLAY:-:0}"

# Locate the X auth cookie. On Xorg this is ~/.Xauthority; on
# Wayland's XWayland it lives under /run/user/$UID/. Whatever
# $XAUTHORITY points to is the authoritative path; fall back to
# ~/.Xauthority for the classic case.
xauth_source="${XAUTHORITY:-$HOME/.Xauthority}"

if [[ ! -r "$xauth_source" ]]; then
  echo "calibrate.sh: X auth cookie not found at $xauth_source" >&2
  echo "  XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset}, DISPLAY=$display" >&2
  echo "  set XAUTHORITY to the real cookie file and re-run" >&2
  exit 1
fi

# Allow the container's X client to reach the host X server. The
# container runs its processes as root, so authorize root (not just
# the invoking host user) and additionally open the family-local
# transport in case the auth cookie isn't shared. Pair with
# `xhost -local: -SI:localuser:root` to revoke after calibration.
if command -v xhost >/dev/null 2>&1; then
  xhost "+SI:localuser:root" >/dev/null
  xhost "+SI:localuser:$(id -un)" >/dev/null
  xhost "+local:" >/dev/null
else
  echo "calibrate.sh: xhost not installed; install x11-xserver-utils or run manually" >&2
fi

echo "calibrate.sh: launching calibrator"
echo "  chessboard inner corners: ${corners}"
echo "  square size:              ${square} m"
echo "  approximate sync window:  ${approx_sync} s"
echo "  DISPLAY:                  ${display}"
echo "  XAUTHORITY (host):        ${xauth_source}"
echo

CHESSBOARD_INNER_CORNERS="${corners}" \
CHESSBOARD_SQUARE_M="${square}" \
APPROXIMATE_SYNC="${approx_sync}" \
DISPLAY="${display}" \
OVCS_XAUTHORITY="${xauth_source}" \
  docker compose -f docker-compose.yml --profile calibration run --rm calibrator
