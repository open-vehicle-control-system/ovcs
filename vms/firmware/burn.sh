#!/usr/bin/env bash
#
# Burn the VMS firmware to an SD card for the vehicle named by $VEHICLE.
#
# Typically invoked via `./ovcs burn <vehicle> vms`, which sets VEHICLE
# and MIX_TARGET. Invoking directly still works: VEHICLE is required,
# MIX_TARGET falls back to the default rpi4 image.
#
set -euo pipefail
cd "$(dirname "$0")"

: "${MIX_TARGET:=ovcs_base_can_system_rpi4}"
: "${VEHICLE:?VEHICLE env var is required (e.g. Ovcs1)}"
export MIX_TARGET VEHICLE

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

step "Fetching Mix dependencies (VEHICLE=$VEHICLE, MIX_TARGET=$MIX_TARGET)"
mix deps.get

step "Writing the firmware image to the target SD card"
mix burn "$@"

step "Done — SD card flashed"
