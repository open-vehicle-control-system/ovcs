#!/usr/bin/env bash
#
# Build the vision firmware for the vehicle named by $VEHICLE.
#
# Dual-mode:
#   * Nerves target (rpi5) — builds the dashboard into vision/api's
#     priv/static, then a .fw image under _build/<target>_dev/nerves/images/.
#     Used by `./ovcs build <vehicle> vision` / `burn` / `upload`.
#   * MIX_TARGET=host — compiles the firmware app for the local machine,
#     for `./ovcs run <vehicle>`, which serves the dashboard from its dev
#     server instead (`VisionFirmware.dev_addons/0`).
#
# Invoking directly: VEHICLE is required; MIX_TARGET falls back to rpi5.
#
set -euo pipefail
cd "$(dirname "$0")"

: "${MIX_TARGET:=rpi5}"
: "${VEHICLE:?VEHICLE env var is required (e.g. OvcsMini)}"
# See vms/firmware/build.sh: the application partition mounts at /data.
: "${NERVES_FW_APPLICATION_PART0_TARGET:=/data}"
export MIX_TARGET VEHICLE NERVES_FW_APPLICATION_PART0_TARGET

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

if [ "$MIX_TARGET" != "host" ]; then
  step "Building the vision dashboard"
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
  # The vehicle is not a dep of vision_firmware; mix.exs's
  # `copy_vehicle_app` release step copies its compiled app in.
  vehicle_dir=$(elixir -e "IO.write(Macro.underscore(\"$VEHICLE\"))")
  step "Compiling vehicle ($VEHICLE → vehicles/$vehicle_dir, MIX_TARGET=host)"
  (
    cd "../../vehicles/$vehicle_dir"
    MIX_TARGET=host mix deps.get
    MIX_TARGET=host mix compile
  )
  step "Assembling the Nerves firmware image"
  mix firmware
  step "Done — firmware is in _build/${MIX_TARGET}_dev/nerves/images/"
fi
