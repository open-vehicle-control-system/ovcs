#!/bin/sh

set -e

FWUP_CONFIG=$NERVES_DEFCONFIG_DIR/fwup.conf

# Run the common post-image processing for nerves
$BR2_EXTERNAL_NERVES_PATH/board/nerves-common/post-createfs.sh $TARGET_DIR $FWUP_CONFIG

# Copy pre-built version of Barebox from the GRiSP project. This one has the
# Nerves U-Boot environment block added to the dts.
cp $NERVES_DEFCONFIG_DIR/barebox-phytec-phycore-imx6ul-emmc-512mb.img $BINARIES_DIR
