#!/usr/bin/env bash
#
# Build the VMS firmware for the vehicle named by $VEHICLE.
#
# Dual-mode:
#   * Nerves target (e.g. ovcs_base_can_system_rpi4) — produces a .fw
#     image under _build/<target>_dev/nerves/images/. Used by
#     `./ovcs build <vehicle> vms` / `burn` / `upload`.
#   * MIX_TARGET=host — compiles the VMS app for the local machine.
#     Used by `./ovcs run <vehicle>` to warm up `_build/dev/lib/`
#     before spawning the BEAM. No firmware image, no dashboard
#     bundle (serve it with `npm run dev` in another terminal).
#
# Invoking directly: VEHICLE is required; MIX_TARGET falls back to
# the rpi4 Nerves target.
#
set -euo pipefail
cd "$(dirname "$0")"

: "${MIX_TARGET:=ovcs_base_can_system_rpi4}"
: "${VEHICLE:?VEHICLE env var is required (e.g. Ovcs1)}"
export MIX_TARGET VEHICLE

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

if [ "$MIX_TARGET" != "host" ]; then
  step "Building the Vue.js debug dashboard"
  (
    cd ../dashboard
    npm install
    npm run build
  )
fi

step "Fetching Mix dependencies (VEHICLE=$VEHICLE, MIX_TARGET=$MIX_TARGET)"
mix deps.get

if [ "$MIX_TARGET" = "host" ]; then
  step "Compiling for host (VEHICLE=$VEHICLE)"
  mix compile
else
  step "Assembling the Nerves firmware image"
  mix firmware
  step "Done — firmware is in _build/${MIX_TARGET}_dev/nerves/images/"
fi
