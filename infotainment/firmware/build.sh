# /bin/sh!
set -e

export MIX_TARGET=ovcs_base_can_system_rpi5
mix deps.get
mix firmware
