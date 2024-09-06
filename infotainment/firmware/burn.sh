# /bin/sh!

set -e

BASEDIR=$(dirname $0)

export MIX_TARGET=ovcs_infotainment_flutter_system_rpi5
cd infotainment/firmware
mix deps.get
mix burn "$@"

