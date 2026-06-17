# Stereo calibration outputs

The `calibrator` compose service writes its captured-samples tarball
into this directory when you click **Save** in the cameracalibrator
GUI (`calibrationdata.tar.gz`). Both the tarball and any extracted
YAMLs are gitignored — capture sessions are reproducible per device,
not source-of-truth artifacts.

## One-shot stereo calibration workflow

Prerequisite: the Elixir perception bridge is already running so
that `/stereo/{left,right}/image_raw/compressed` are live. Verify
with `docker compose exec ros2 ros2 topic list`.

1. **Print a chessboard.** Default expected by the service is
   an **8×6 inner-corner** board with **25 mm squares** — i.e.
   a 9-column × 7-row grid of black/white squares. Use ROS's
   `check-7x6.pdf` rotated 90° or any standard cv chessboard.
   Override via env if you printed a different one:
   ```
   CHESSBOARD_INNER_CORNERS=9x6 CHESSBOARD_SQUARE_M=0.030 \
     docker compose run --rm calibrator
   ```

2. **Allow the container to draw on your X display** (host
   one-liner — needed only once per session):
   ```
   xhost +SI:localuser:$(id -un)
   ```

3. **Launch the calibrator:**
   ```
   docker compose run --rm calibrator
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

5. **Click SAVE.** The GUI writes
   `/output/calibrationdata.tar.gz` (i.e. this directory) and
   prints the path.

6. **Extract and install:**
   ```
   tar xzf calibrationdata.tar.gz
   cp left.yaml  ../../vehicles/ovcs_mini/priv/calibration/stereo_left.yaml
   cp right.yaml ../../vehicles/ovcs_mini/priv/calibration/stereo_right.yaml
   ```

7. **Re-run the bridge.** The `Stereo.OpenCV` backend reads
   the new YAMLs at boot and the disparity → depth numbers now
   reflect the actual physical geometry.

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
