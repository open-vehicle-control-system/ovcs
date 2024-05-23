# /bin/sh!

set -e

export MIX_TARGET=ovcs_infotainment_flutter_system_rpi4
cd infotainment/dashboard_flutter
flutterpi_tool build --arch=arm64 --release
cd ..
cp -rf dashboard_flutter/build/flutter_assets firmware_flutter/rootfs_overlay/var/
cd firmware_flutter
mix firmware

