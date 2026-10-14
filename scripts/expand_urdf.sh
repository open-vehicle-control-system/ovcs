#!/usr/bin/env bash
#
# Expand each vehicle's xacro into the URDF committed beside it, which
# the vehicle package reads at compile time. Needs `xacro` on the PATH
# (`source /opt/ros/<distro>/setup.bash`).
#
#   mise run urdf
set -euo pipefail
cd "$(dirname "$0")/.."
common_dir="$PWD/compose/local/simulation/common"

# From the model's directory, so its mesh paths stay relative to it.
for model in vehicles/*/description/*.urdf.xacro; do
  (cd "$(dirname "$model")" && xacro "$(basename "$model")" common_dir:="$common_dir" -o "$(basename "${model%.xacro}")")
  echo "==> ${model%.xacro}"
done
