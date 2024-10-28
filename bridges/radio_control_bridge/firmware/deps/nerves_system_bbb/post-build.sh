#!/bin/sh

set -e

# Clear the MAC address on the TI WL18xx .bin file.
#
# NOTE: This is only relevant for the BBG Wireless and any other board using
#       a TI WiLink WiFi module.
#
# If the MAC address field is set to 0, the WL18xx parts will use whatever
# TI programmed into the module's fuses. The wl127x-nvs.bin file distributed
# with the linux-firmware package has the MAC address set to 00:00:de:ad:be:ef
# which isn't that useful.
#
# See the following for more details:
# https://github.com/nerves-project/nerves_system_bbb/pull/19
# http://processors.wiki.ti.com/index.php/WL18xx_Writing_MAC_address

# The format from the calibrator utility is:
#   Byte offset         Description
#   3                   mac_addr[5]
#   4                   mac_addr[4]
#   5                   mac_addr[3]
#   6                   mac_addr[2]
#   10                  mac_addr[1]
#   11                  mac_addr[0]
#
dd if=/dev/zero of=$TARGET_DIR/lib/firmware/ti-connectivity/wl127x-nvs.bin \
    bs=1 count=4 seek=3 2> /dev/null
dd if=/dev/zero of=$TARGET_DIR/lib/firmware/ti-connectivity/wl127x-nvs.bin \
    bs=1 count=2 seek=10 2> /dev/null

# Create the fwup ops script to handling MicroSD/eMMC operations at runtime
# NOTE: revert.fw is the previous, more limited version of this. ops.fw is
#       backwards compatible.
mkdir -p $TARGET_DIR/usr/share/fwup
$HOST_DIR/usr/bin/fwup -c -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf -o $TARGET_DIR/usr/share/fwup/ops.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw

# Copy the fwup includes to the images dir
cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR

# Since U-Boot's squashfs support is so slow (sadly), store the Linux
# kernel in the FAT filesystem instead of /boot. Everything else can
# go in /boot since it's so small. See the fwup.conf for how the zImage
# is put in the FAT filesystem. Remove zImage from /boot since we can't
# tell Buildroot to just put the .dtb files there.
rm -f $TARGET_DIR/boot/zImage
