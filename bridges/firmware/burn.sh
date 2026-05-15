#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

: "${VEHICLE:?VEHICLE env var is required}"
: "${BRIDGE_FIRMWARE_ID:?BRIDGE_FIRMWARE_ID env var is required}"
: "${MIX_TARGET:?MIX_TARGET env var is required}"
export VEHICLE BRIDGE_FIRMWARE_ID MIX_TARGET

mix deps.get
mix burn "$@"
