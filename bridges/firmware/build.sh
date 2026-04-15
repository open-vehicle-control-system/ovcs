#!/usr/bin/env bash
#
# Build a bridge firmware image for $VEHICLE / $BRIDGE_FIRMWARE_ID.
#
# Typically invoked via `./ovcs build <vehicle> <firmware-id>`, which
# sets VEHICLE, BRIDGE_FIRMWARE_ID, and MIX_TARGET. Direct invocation
# requires all three env vars.
#
set -euo pipefail
cd "$(dirname "$0")"

: "${VEHICLE:?VEHICLE env var is required (e.g. Ovcs1)}"
: "${BRIDGE_FIRMWARE_ID:?BRIDGE_FIRMWARE_ID env var is required (e.g. radio_control)}"
: "${MIX_TARGET:?MIX_TARGET env var is required (resolved from vehicle bridge_firmwares)}"
export VEHICLE BRIDGE_FIRMWARE_ID MIX_TARGET

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

step "Fetching Mix dependencies (VEHICLE=$VEHICLE, BRIDGE_FIRMWARE_ID=$BRIDGE_FIRMWARE_ID, MIX_TARGET=$MIX_TARGET)"
mix deps.get

step "Assembling the Nerves firmware image"
mix firmware

step "Done — firmware is in _build/${MIX_TARGET}_dev/nerves/images/"
