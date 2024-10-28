#!/bin/sh

#
# Run a nerves_system_x86_64-based image in QEMU
#
# Usage:
#   run-qemu.sh [Path to .img file]
#

set -e

IMAGE="$1"
DEFAULT_IMAGE="<%= image_path %>"

help() {
    echo
    echo "Usage:"
    echo "  run-qemu.sh [Path to .img file]"
    echo
    echo "Run 'mix firmware.image' to create the starter image. Since qemu isn't"
    echo "supported by Nerves, we don't have instructions for how to make this a"
    echo "productive development environment. You should be able to see this"
    echo "boot, though."
    exit 1
}
[ -n "$IMAGE" ] || IMAGE="$DEFAULT_IMAGE"

[ -f "$IMAGE" ] || (echo "Error: can't find '$IMAGE'"; help)

echo "Starting QEMU..."
qemu-system-x86_64 \
    -drive file="$IMAGE",if=virtio,format=raw \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::10022-:22 \
    -serial stdio
