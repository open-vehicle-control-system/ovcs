#!/usr/bin/env bash
# CMD for the calibrator one-shot service. Subscribes to the vision
# unit's /stereo/{left,right}/image_raw/compressed topics, or a camera
# of its own's /<camera>/image_raw/compressed, decompresses
# them so the calibrator can consume raw `sensor_msgs/Image`, then
# launches the standard ROS 2 `cameracalibrator` GUI: in stereo mode for
# the stereo pair, the default, or in monocular mode for the camera of
# its own CALIBRATION_CAMERA names.
#
# Runs under the shared entrypoint, which has already prepared Zenoh
# + sourced the ROS overlay.
#
# Workflow:
#   1. The vision unit must already be streaming the cameras, its ROS 2
#      exporter publishing them (stereo:, and cameras: for a camera of
#      its own).
#   2. Run this service: compose/local/scripts/calibrate.sh, or
#      compose/local/scripts/calibrate.sh --camera center for a camera.
#   3. Wave a chessboard until the coverage bars are green, click
#      CALIBRATE, wait for the solver, then COMMIT to store the
#      calibration on the unit through set_camera_info, or SAVE.
#   4. SAVE's tarball lands at
#      compose/local/calibration_output/calibrationdata.tar.gz
#      on the host.

set -euo pipefail

: "${CHESSBOARD_INNER_CORNERS:=8x6}"
: "${CHESSBOARD_SQUARE_M:=0.025}"
: "${APPROXIMATE_SYNC:=0.05}"
: "${CALIBRATION_CAMERA:=}"

# The namespace the cameras are under: the stereo unit's prefix, none for
# a camera of its own unless its exporter gives it a topic_prefix.
if [[ -n "${CALIBRATION_CAMERA}" ]]; then
  : "${CALIBRATION_TOPIC_PREFIX:=}"
  cameras=("${CALIBRATION_CAMERA}")
else
  : "${CALIBRATION_TOPIC_PREFIX:=stereo}"
  cameras=(left right)
fi
prefix="${CALIBRATION_TOPIC_PREFIX:+/${CALIBRATION_TOPIC_PREFIX}}"

# Waits up to 15 s for every topic named after the cameras with `suffix`.
wait_for_topics() {
  local suffix="$1"
  local topics=()
  for camera in "${cameras[@]}"; do topics+=("${prefix}/${camera}/${suffix}"); done
  echo "calibrator: waiting for ${topics[*]} …"
  timeout 15 bash -c '
    while true; do
      list=$(ros2 topic list 2>/dev/null)
      missing=0
      for topic in "$@"; do
        echo "$list" | grep -qx "$topic" || missing=1
      done
      [ "$missing" -eq 0 ] && exit 0
      sleep 1
    done
  ' _ "${topics[@]}"
}

# Pre-flight: with rmw_zenoh, a missing topic simply never delivers a
# sample and the GUI sits idle forever.
wait_for_topics image_raw/compressed || {
  echo "calibrator: camera topics not visible — is the vision unit publishing them?" >&2
  exit 1
}
echo "calibrator: camera topics found"

# Decompress through a rclpy helper: `image_transport republish` and the
# vision unit disagree on the CompressedImage rmw_zenoh type hash, so it
# silently drops every frame.
echo "calibrator: starting decompress helper"
decompress_stereo "${CALIBRATION_TOPIC_PREFIX}" "${cameras[@]}" &
DECOMPRESS_PID=$!
trap "kill ${DECOMPRESS_PID} 2>/dev/null || true" EXIT

# cameracalibrator polls subscribers at startup: a missing topic means a
# permanently blank window.
wait_for_topics image_calibration || {
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

echo "calibrator: launching cameracalibrator for ${cameras[*]}"
echo "  chessboard inner corners: ${CHESSBOARD_INNER_CORNERS}"
echo "  square size:              ${CHESSBOARD_SQUARE_M} m"
echo "  approximate sync window:  ${APPROXIMATE_SYNC} s"
echo

if [[ -n "${CALIBRATION_CAMERA}" ]]; then
  camera="${prefix}/${CALIBRATION_CAMERA}"
  # Unbuffered, so CALIBRATE's results reach the terminal as they are printed.
  PYTHONUNBUFFERED=1 exec ros2 run camera_calibration cameracalibrator \
    --size "${CHESSBOARD_INNER_CORNERS}" \
    --square "${CHESSBOARD_SQUARE_M}" \
    --no-service-check \
    image:="${camera}/image_calibration" \
    camera:="${camera}" \
    camera/set_camera_info:="${camera}/set_camera_info"
fi

PYTHONUNBUFFERED=1 exec ros2 run camera_calibration cameracalibrator \
  --size "${CHESSBOARD_INNER_CORNERS}" \
  --square "${CHESSBOARD_SQUARE_M}" \
  --approximate "${APPROXIMATE_SYNC}" \
  --no-service-check \
  right:="${prefix}/right/image_calibration" \
  left:="${prefix}/left/image_calibration" \
  right_camera:="${prefix}/right" \
  left_camera:="${prefix}/left" \
  left_camera/set_camera_info:="${prefix}/left/set_camera_info" \
  right_camera/set_camera_info:="${prefix}/right/set_camera_info"
