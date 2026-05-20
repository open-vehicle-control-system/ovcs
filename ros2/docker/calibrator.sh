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

# Republish compressed → raw on the two sides. Background processes
# so the calibrator (foreground) can subscribe to the raw topics.
ros2 run image_transport republish compressed \
  in/compressed:=/stereo/left/image_raw/compressed \
  out:=/stereo/left/image_raw &
LEFT_REPUB_PID=$!

ros2 run image_transport republish compressed \
  in/compressed:=/stereo/right/image_raw/compressed \
  out:=/stereo/right/image_raw &
RIGHT_REPUB_PID=$!

# Clean up the republishers on Ctrl-C or normal exit.
trap "kill ${LEFT_REPUB_PID} ${RIGHT_REPUB_PID} 2>/dev/null || true" EXIT

# Give the republishers a moment to declare their publishers.
sleep 2

# Tell the GUI to save its tarball into the mounted /output volume
# so the YAMLs survive when the container exits.
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
  right:=/stereo/right/image_raw \
  left:=/stereo/left/image_raw \
  right_camera:=/stereo/right \
  left_camera:=/stereo/left
