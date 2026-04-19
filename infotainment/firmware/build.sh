#!/usr/bin/env bash
#
# Build the infotainment firmware for the vehicle named by $VEHICLE.
#
# Dual-mode:
#   * Nerves target (e.g. ovcs_base_can_system_rpi5) — produces a .fw
#     image under _build/<target>_dev/nerves/images/. The Flutter app
#     is bundled in-release by `nerves_flutter_support`. Used by
#     `./ovcs build <vehicle> infotainment` / `burn` / `upload`.
#   * MIX_TARGET=host — compiles the infotainment app for the local
#     machine (no Flutter bundling). Used by `./ovcs run <vehicle>`.
#
# Invoking directly: VEHICLE is required; MIX_TARGET falls back to
# the rpi5 Nerves target.
#
set -euo pipefail
cd "$(dirname "$0")"

: "${MIX_TARGET:=ovcs_base_can_system_rpi5}"
: "${VEHICLE:?VEHICLE env var is required (e.g. Ovcs1)}"
export MIX_TARGET VEHICLE

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

step "Fetching Mix dependencies (VEHICLE=$VEHICLE, MIX_TARGET=$MIX_TARGET)"
mix deps.get

if [ "$MIX_TARGET" = "host" ]; then
  step "Compiling for host (VEHICLE=$VEHICLE)"
  mix compile
else
  step "Assembling the Nerves firmware image (Flutter app is built in-release)"
  mix firmware
  step "Done — firmware is in _build/${MIX_TARGET}_dev/nerves/images/"
fi
