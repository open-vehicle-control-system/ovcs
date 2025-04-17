# /bin/sh!
export MIX_TARGET=ovcs_infotainment_flutter_system_rpi5
mix deps.get
mix burn "$@"
