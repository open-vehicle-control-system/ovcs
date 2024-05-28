# /bin/sh!

set -e

export MIX_TARGET=ovcs_infotainment_flutter_system_rpi4
cd infotainment/dashboard
flutterpi_tool build --arch=arm64 --release
cp -rf build/flutter_assets ../firmware/rootfs_overlay/var/
cd ../firmware
mix deps.get
mix firmware

