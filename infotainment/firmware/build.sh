#!/usr/bin/env bash
#
# Build the infotainment firmware for the vehicle named by $VEHICLE.
#
# Typically invoked via `./ovcs build <vehicle> infotainment`, which
# sets VEHICLE and MIX_TARGET. Invoking directly still works: VEHICLE
# is required, MIX_TARGET falls back to the default rpi5 image.
#
set -euo pipefail
cd "$(dirname "$0")"

: "${MIX_TARGET:=ovcs_base_can_system_rpi5}"
: "${VEHICLE:?VEHICLE env var is required (e.g. Ovcs1)}"
export MIX_TARGET VEHICLE

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

step "Fetching Mix dependencies (VEHICLE=$VEHICLE, MIX_TARGET=$MIX_TARGET)"
mix deps.get

step "Assembling the Nerves firmware image (Flutter app is built in-release)"
mix firmware

step "Done — firmware is in _build/${MIX_TARGET}_dev/nerves/images/"
