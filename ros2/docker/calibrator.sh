#!/usr/bin/env bash
# CMD for the calibrator one-shot service. Subscribes to the bridge's
# /stereo/{left,right}/image_raw/compressed topics, starts an
# `image_transport republish` for each side so the calibrator can
# consume raw `sensor_msgs/Image`, then launches the standard ROS 2
# `cameracalibrator` GUI.
#
# Runs under the shared entrypoint, which has already prepared Zenoh
# + sourced the ROS overlay.
#
# Workflow:
#   1. The Elixir bridge must already be running with both cameras
#      streaming (./ovcs run ovcs_mini).
#   2. Allow X access from the container:
#        xhost +SI:localuser:$(id -un)
#   3. Run this service: docker compose run --rm calibrator
#   4. Wave a chessboard (default 8x6 inner corners, 25 mm squares)
#      until all four coverage bars are green, click CALIBRATE,
#      wait for the solver, click SAVE.
#   5. The tarball lands at ros2/calibration_output/calibrationdata.tar.gz
#      on the host. Extract → drop left.yaml + right.yaml into
#      vehicles/ovcs_mini/priv/calibration/stereo_{left,right}.yaml.

set -euo pipefail

: "${CHESSBOARD_INNER_CORNERS:=8x6}"
: "${CHESSBOARD_SQUARE_M:=0.025}"
: "${APPROXIMATE_SYNC:=0.05}"

# Pre-flight: confirm the bridge is publishing the compressed
# streams we'll republish. cameracalibrator is happiest when both
# topics already exist; with rmw_zenoh, missing topics simply
# never deliver a sample and the GUI sits idle forever.
echo "calibrator: waiting for /stereo/left/image_raw/compressed + /stereo/right/image_raw/compressed …"
timeout 15 bash -c '
  while true; do
    list=$(ros2 topic list 2>/dev/null)
    echo "$list" | grep -q "^/stereo/left/image_raw/compressed$" \
      && echo "$list" | grep -q "^/stereo/right/image_raw/compressed$" \
      && exit 0
    sleep 1
  done
' || {
  echo "calibrator: bridge topics not visible — is `./ovcs run ovcs_mini` actually running?" >&2
  exit 1
}
echo "calibrator: bridge topics found"

# Decompress the bridge's compressed stereo feeds into raw
# `sensor_msgs/Image` topics via a rclpy helper. We do this instead
# of `image_transport republish` because the latter and the bridge
# disagree on the CompressedImage rmw_zenoh type hash, so it
# silently drops every frame. rclpy's plain subscriber path works.
echo "calibrator: starting decompress helper"
decompress_stereo &
DECOMPRESS_PID=$!
trap "kill ${DECOMPRESS_PID} 2>/dev/null || true" EXIT

# Wait for the helper to start publishing the raw topics before
# launching the GUI — cameracalibrator polls subscribers at startup
# and a missing topic means a permanently blank window.
echo "calibrator: waiting for /stereo/{left,right}/image_calibration …"
timeout 15 bash -c '
  while true; do
    list=$(ros2 topic list 2>/dev/null)
    echo "$list" | grep -q "^/stereo/left/image_calibration$" \
      && echo "$list" | grep -q "^/stereo/right/image_calibration$" \
      && exit 0
    sleep 1
  done
' || {
  echo "calibrator: decompress helper never produced raw topics" >&2
  exit 1
}
echo "calibrator: decompress helper ready"

# cameracalibrator writes the tarball at a hardcoded
# /tmp/calibrationdata.tar.gz regardless of working directory.
# Symlink so the file actually lands in the host bind-mount under
# /output and survives the --rm container exit.
ln -sf /output/calibrationdata.tar.gz /tmp/calibrationdata.tar.gz

cd /output

echo "calibrator: launching cameracalibrator"
echo "  chessboard inner corners: ${CHESSBOARD_INNER_CORNERS}"
echo "  square size:              ${CHESSBOARD_SQUARE_M} m"
echo "  approximate sync window:  ${APPROXIMATE_SYNC} s"
echo

exec ros2 run camera_calibration cameracalibrator \
  --size "${CHESSBOARD_INNER_CORNERS}" \
  --square "${CHESSBOARD_SQUARE_M}" \
  --approximate "${APPROXIMATE_SYNC}" \
  --no-service-check \
  right:=/stereo/right/image_calibration \
  left:=/stereo/left/image_calibration \
  right_camera:=/stereo/right \
  left_camera:=/stereo/left \
  left_camera/set_camera_info:=/stereo/left/set_camera_info \
  right_camera/set_camera_info:=/stereo/right/set_camera_info
