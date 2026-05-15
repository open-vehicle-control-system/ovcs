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
# See vms/firmware/build.sh for why we override the application
# partition target to /data.
: "${NERVES_FW_APPLICATION_PART0_TARGET:=/data}"
export MIX_TARGET VEHICLE NERVES_FW_APPLICATION_PART0_TARGET

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

step "Fetching Mix dependencies (VEHICLE=$VEHICLE, MIX_TARGET=$MIX_TARGET)"
mix deps.get

if [ "$MIX_TARGET" = "host" ]; then
  step "Compiling for host (VEHICLE=$VEHICLE)"
  mix compile
else
  # See vms/firmware/build.sh for the full rationale.
  vehicle_dir=$(elixir -e "IO.write(Macro.underscore(\"$VEHICLE\"))")
  step "Compiling vehicle ($VEHICLE → vehicles/$vehicle_dir, MIX_TARGET=host)"
  (
    cd "../../vehicles/$vehicle_dir"
    MIX_TARGET=host mix deps.get
    MIX_TARGET=host mix compile
  )
  step "Assembling the Nerves firmware image (Flutter app is built in-release)"
  mix firmware
  step "Done — firmware is in _build/${MIX_TARGET}_dev/nerves/images/"
fi
