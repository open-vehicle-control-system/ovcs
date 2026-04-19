#!/usr/bin/env bash
#
# Build the shared bridges firmware for $VEHICLE / $BRIDGE_FIRMWARE_ID.
#
# Dual-mode:
#   * Nerves target (e.g. ovcs_base_can_system_rpi3a) — produces a .fw
#     image for the named bridge entry. VEHICLE, BRIDGE_FIRMWARE_ID,
#     and MIX_TARGET are all required; `./ovcs build <v> <id>` fills
#     them in.
#   * MIX_TARGET=host — compiles `bridge_firmware` for the local
#     machine. BRIDGE_FIRMWARE_ID is not used at compile time (only
#     at BEAM start, set per role by `./ovcs run`), so it defaults
#     to `radio_control` purely to satisfy `config/config.exs`.
#
set -euo pipefail
cd "$(dirname "$0")"

: "${VEHICLE:?VEHICLE env var is required (e.g. Ovcs1)}"
: "${MIX_TARGET:?MIX_TARGET env var is required (Nerves target atom, or 'host')}"

if [ "$MIX_TARGET" = "host" ]; then
  : "${BRIDGE_FIRMWARE_ID:=radio_control}"
else
  : "${BRIDGE_FIRMWARE_ID:?BRIDGE_FIRMWARE_ID env var is required (e.g. radio_control)}"
fi
export VEHICLE BRIDGE_FIRMWARE_ID MIX_TARGET

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

step "Fetching Mix dependencies (VEHICLE=$VEHICLE, BRIDGE_FIRMWARE_ID=$BRIDGE_FIRMWARE_ID, MIX_TARGET=$MIX_TARGET)"
mix deps.get

if [ "$MIX_TARGET" = "host" ]; then
  step "Compiling for host (VEHICLE=$VEHICLE)"
  mix compile
else
  step "Assembling the Nerves firmware image"
  mix firmware
  step "Done — firmware is in _build/${MIX_TARGET}_dev/nerves/images/"
fi
