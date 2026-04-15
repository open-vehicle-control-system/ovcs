# /bin/sh!
set -e

: "${MIX_TARGET:=ovcs_base_can_system_rpi5}"
export MIX_TARGET
mix deps.get
mix firmware
