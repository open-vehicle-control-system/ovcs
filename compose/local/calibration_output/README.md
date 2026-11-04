# Stereo calibration outputs

The vision unit's dashboard calibrates its cameras on its own, with
the same OpenCV steps and defaults as `cameracalibrator`, and needs
neither ROS 2 nor an X display: see
[Calibrate the cameras](../../../docs/vision/calibration.md). This
directory serves the other path, `cameracalibrator` over ROS 2, which
commits through the same code on the unit.

The `calibrator` compose service writes its captured-samples tarball
into this directory when you click **Save** in the cameracalibrator
GUI (`calibrationdata.tar.gz`). Both the tarball and any extracted
YAMLs are gitignored — capture sessions are reproducible per device,
not source-of-truth artifacts.

## One-shot stereo calibration workflow

Prerequisite: the vision unit's stereo cameras are already running so
that `/stereo/{left,right}/image_raw/compressed` are live. Verify
with `docker compose exec ros2 ros2 topic list`.

1. **Print a chessboard.** Default expected by the service is
   an **8×6 inner-corner** board with **25 mm squares** — i.e.
   a 9-column × 7-row grid of black/white squares. Use ROS's
   `check-7x6.pdf` rotated 90° or any standard cv chessboard.
   Override via env if you printed a different one:
   ```
   CHESSBOARD_INNER_CORNERS=9x6 CHESSBOARD_SQUARE_M=0.030 \
     ../scripts/calibrate.sh
   ```

2. **Allow the container to draw on your X display** (host
   one-liner — needed only once per session):
   ```
   xhost +SI:localuser:$(id -un)
   ```

3. **Launch the calibrator:**
   ```
   ../scripts/calibrate.sh
   ```
   An OpenCV window appears with both camera feeds side-by-side
   and four coverage bars (X / Y / Size / Skew). Wave the
   chessboard slowly through every quadrant, angle, and depth
   until all four bars go green and the **CALIBRATE** button
   activates.

4. **Click CALIBRATE.** The solver runs for ~30–60 s on a laptop
   CPU and prints intrinsics + extrinsics to the terminal.
   Inspect the reported RMS reprojection error — a typical good
   calibration is **< 0.5 px**; >2 px means more samples / better
   board angles are needed.

5. **Click SAVE** to keep the samples and YAMLs: the
   GUI writes `/output/calibrationdata.tar.gz` (i.e. this
   directory).

6. **Click COMMIT** to apply it now. The vision unit reloads the new
   calibration live and keeps it across restarts in its
   `:calibration_store_dir`, `/data/vision/calibration/` on the OVCS
   Mini (the firmware's own files are read-only), which it prefers at
   boot once both sides are there. A unit without a calibration
   restarts with its depth pipeline once both sides are written. The
   dashboard's Calibration page then shows it in use. The calibrator
   exits after COMMIT.

7. **Install it in your vehicle package,** so a fresh firmware or
   a wiped data partition gets it too. Either extract the tarball:
   ```
   tar xzf calibrationdata.tar.gz
   cp left.yaml  ../../../vehicles/<vehicle>/priv/calibration/stereo_left.yaml
   cp right.yaml ../../../vehicles/<vehicle>/priv/calibration/stereo_right.yaml
   ```
   or download them from the dashboard's Calibration page, or copy
   the committed files off the vehicle:
   ```
   sftp <vehicle>-vision.local:/data/vision/calibration/stereo_left.yaml  ../../../vehicles/<vehicle>/priv/calibration/
   sftp <vehicle>-vision.local:/data/vision/calibration/stereo_right.yaml ../../../vehicles/<vehicle>/priv/calibration/
   ```

## Troubleshooting

- **Window doesn't appear / "cannot connect to display":** the
  `xhost +SI:...` step is missing or your `DISPLAY` is not `:0`.
  Set `DISPLAY=:1` (or whatever `echo $DISPLAY` reports on the
  host) in the env before running.
- **Coverage bars never fill in one axis:** you need samples
  with the board at that extreme of the frame. The X bar wants
  side-to-side coverage, Y top-bottom, Size near vs far, Skew
  tilted vs flat.
- **"Could not synchronize" warnings:** the two USB cameras
  drifted further apart than the `APPROXIMATE_SYNC` window.
  Bump `APPROXIMATE_SYNC=0.10` and re-launch.
