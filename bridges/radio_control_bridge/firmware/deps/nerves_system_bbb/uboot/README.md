# U-Boot patches

The patches and base U-Boot environment come from Robert Nelson's
Bootloader-Builder project for the BeagleBones and other boards.

See https://github.com/RobertCNelson/Bootloader-Builder/tree/master/patches

The strategy is to follow his patches pretty closely, but to make the following
modifications:

1. Store the U-Boot environment raw on MMC. Upstream stores it in a file and
   that's not as convenient.
2. Enable SquashFS. Nerves uses read-only SquashFS root filesystems rather than
   writable EXT4 ones.
3. Support A/B firmware updates

The U-Boot environment and A/B changes force replicating and modifying the
default environment to the uboot.env file.
