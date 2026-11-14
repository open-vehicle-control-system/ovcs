---
title: Calibrate the cameras
description: How to calibrate the vision unit's stereo cameras, or a camera of its own, from its dashboard or with ROS 2's cameracalibrator, where the unit keeps the calibration, and how to install one in your vehicle package.
---

Depth needs a calibration of the two cameras: each one's focal length, centre and lens distortion, and how the right camera sits relative to the left one. [Stereo vision basics](./basics.md#calibration) explains what it holds. The vision unit computes it from views of a printed chessboard, either on its own, from the dashboard's Calibration page, or through ROS 2's `cameracalibrator`. Both run the same OpenCV steps, with the same defaults, and commit the calibration the same way.

The examples use the OVCS Mini reference vehicle's vision unit; everything works the same on your vehicle, with its names and paths.

## Calibrate from the dashboard

Open the dashboard (`https://<vehicle>-vision.local`) and choose **Stereo cameras** in the menu's **Calibration** section, or go to `?calibration=<id>`, the stereo unit's prefix. The page shows the steps of a new calibration, then the one in use. You need nothing but the unit, a browser and the board.

The unit holds one calibration session, shared by every dashboard: a second browser on the page sees the same capture and can carry it on. The unit looks for the board only while a dashboard has the Calibration page open, 15 times a second at most, so calibrating costs nothing when no one is. Closing the page stops the detection and keeps the samples; opening it again shows the capture where it was.

### The board

Print a chessboard and glue it flat to something rigid; a board that bends gives a wrong calibration. Measure one square with a ruler after printing, as printers scale.

Enter the board in **inner corners**, the points where four squares meet, not in squares: a board of 9 × 7 squares has 8 × 6 inner corners. The columns and rows must differ, as a board with as many of each looks the same turned a quarter, and both must be 2 or more. Then enter the side of one square in millimetres. The page starts with 8 × 6 inner corners and 25 mm, and your browser remembers what you enter.

**Start capturing** begins the capture.

### Capture

Both camera previews show the corners the unit finds, joined row by row: in one colour when the board is found, in green when that view is kept as a sample. While neither camera finds the board, the page names the board it looks for, in inner corners and in squares; a board that is never found is most often one entered in squares.

A view counts only when both cameras see the whole board, with every corner at least 8 pixels inside the frame. It is kept as a sample when it differs enough from every sample already kept: its position across and down the image, its apparent size and its tilt. Move the board slowly, as a blurred board is not found, and cover:

- the left and right edges of the image, and the top and bottom;
- near, with the board filling much of the image, and far;
- tilted left, right, up and down.

Four gauges beside the previews follow the coverage, each with the name `cameracalibrator` gives it: **Left to right (X)** and **Top to bottom (Y)** the spread of positions across and down, **Near to far (size)** the spread of apparent sizes, **Tilted (skew)** the spread of tilts. A gauge turns green once full. **Compute calibration** is enabled once every gauge is full, or at 40 views kept. **Cancel** ends the session and drops the views.

### Solve and read the errors

**Compute calibration** has the unit compute the calibration from the samples, with OpenCV, in the steps and with the defaults of `cameracalibrator`: each camera alone (`plumb_bob` distortion, with `k3` held at 0), then the right camera's position relative to the left one, the intrinsics held, then the rectification. A calibration from the page compares one to one with one from `cameracalibrator` on the same board and moves. **Cancel** stops it and ends the session. When it fails, the capture resumes with the error shown, so you can add samples and try again.

The result shows three reprojection errors, in pixels: how far, on average, the corners the calibration predicts land from the corners found, for each camera and for the pair.

| RMS error | Verdict |
|---|---|
| under 0.5 px | good |
| 0.5 to 2 px | fair |
| over 2 px | poor: capture again, with more samples and better coverage |

Next to them, the **Distance between cameras (baseline)** and the **Focal length (fx)**, the left camera's after rectification (the `fx` of its projection matrix), beside the values the unit uses now, when it has a calibration. Each camera's own `fx`, before rectification, is among the camera parameters in the page's first part. The baseline should match the distance between the two lenses, measured with a ruler: a different one usually means a wrong square size, as the baseline scales with it.

### Use the calibration

- **Use this calibration** has the unit take the calibration. The session shows it applying, which cannot be cancelled, and the outcome follows: the calibration in use changes and the page goes back to the board, or the unit refuses it, its files go back as they were, and the result stays, with the reason. The depth uses the new calibration from one of the next pairs, the ROS 2 exporter's `camera_info` follows without a restart, and the automatic row correction (`right_row_offset`, see [Stereo stages](./stages.md#1-rectification)) starts again from 0.
- **Download** saves the two YAML files, `<prefix>_left.yaml` and `<prefix>_right.yaml`, where `<prefix>` is the `:stereo` component's `:prefix`, `stereo` by default (`stereo_left.yaml` and `stereo_right.yaml` on the OVCS Mini), to [install in your vehicle package](#install-it-in-your-vehicle-package).
- **Discard** drops the result and the samples.

## A camera of its own

A unit with a camera of its own, such as the OVCS1 reference vehicle's center camera, lists it in the menu's **Calibration** section, under **Stereo cameras**, as **Center camera** on the OVCS1. Open it, then follow the same steps: the page shows that camera alone, a view becomes a sample when the camera sees the board, and the result has one reprojection error and no baseline.

The unit looks for the board in the image output it receives from the camera, and the calibration is for that image's size; the unit scales it to the camera's other outputs. An apply stores it as `camera_<name>.yaml` in the camera's `calibration_store_dir`, or over its `calibration:` file without a store. The ROS 2 exporter publishes it as the camera's info at once. The camera's detection and segmentation pipelines read the calibration when they start, so restart the unit for them to take it.

The camera's pose relative to the stereo pair is a separate file, its `pose:`, which the page does not write.

## Where the calibration lives

The `:stereo` component of your vehicle's vision composer names two places, documented in `VisionCore.Stereo.Supervisor`:

| Calibration | Option | Files | On the OVCS Mini |
|---|---|---|---|
| Built-in | `:calibration_dir`, or each side's `:calibration_path` | `<prefix>_left.yaml`, `<prefix>_right.yaml` in the directory | `vehicles/ovcs_mini/priv/calibration/`, shipped in the firmware, read-only |
| Stored on the unit | `:calibration_store_dir` | the same names | `/data/vision/calibration/`, on the writable data partition |

```elixir
{:stereo,
 driver: VisionCore.Camera.LibCamera,
 calibration_dir: Application.app_dir(:my_car, "priv/calibration"),
 calibration_store_dir: "/data/vision/calibration",
 left: [...],
 right: [...]}
```

A commit, from the dashboard or from `cameracalibrator`, writes the store. Once both sides are stored, the stored calibration is the one in force, at every boot, over the built-in one; with one side stored alone, the built-in one stays in force. Each file is written whole or not at all, and commits run one at a time.

Without a `:calibration_store_dir`, a commit writes the built-in files themselves, and there is nothing to go back to. On a workstation, where Mix links your vehicle's `priv` into its build, those are the files in `vehicles/<vehicle>/priv/calibration/`: `git diff` shows the change.

The page's first part says which is in force: **Using the calibration shipped with the firmware**, **Calibrated on this unit** with the time, or **Not calibrated**. Under it, the image size, the focal length, whether the lens distortion is corrected, which a calibration with every distortion coefficient at 0 does not, and for a pair the distance between the cameras; a unit without a calibration shows a dash for each. Beside them, the camera parameters: each camera's `fx`, `fy`, `cx`, `cy` and distortion coefficients, in pixels; **Download** saves the two files in use. **Calibrate again**, or **Calibrate** on a unit without a calibration, opens a dialog that makes a new one in three steps: the board, the capture, the result. The dialog stays open while a session runs, in every browser on the page, until its own buttons end it.

**Go back to the firmware's calibration**, shown while anything is stored on the unit, a side stored alone included, and a built-in calibration exists, deletes the stored files after asking, and the unit takes the built-in calibration again. A firmware upload keeps the data partition, and with it the stored calibration; wiping the partition loses it.

## Install it in your vehicle package

The stored calibration belongs to one unit. To ship it in the firmware, so that a new board, or one whose data partition was wiped, starts calibrated:

1. Get the two files: **Download** on the result before applying it, or on the calibration in use after, or copy them off the unit:

   ```sh
   sftp <vehicle>-vision.local:/data/vision/calibration/stereo_left.yaml  vehicles/<vehicle>/priv/calibration/
   sftp <vehicle>-vision.local:/data/vision/calibration/stereo_right.yaml vehicles/<vehicle>/priv/calibration/
   ```

   The path is your `:calibration_store_dir`, the file names `<prefix>_<side>.yaml`.

2. Put them in the directory your `:calibration_dir` names. On the OVCS Mini reference vehicle it is `vehicles/ovcs_mini/priv/calibration/`; it works the same on your vehicle, with its own directory.
3. List them in your composer's `required_files/0`, so a build without them fails:

   ```elixir
   @impl VisionCore.Composer
   def required_files, do: ["priv/calibration/stereo_left.yaml", "priv/calibration/stereo_right.yaml"]
   ```

4. Build and upload the firmware (`./ovcs upload <vehicle> vision`). The stored calibration stays in force until you **Go back to the firmware's calibration**; then the page reads Using the calibration shipped with the firmware.

A calibration holds for one sensor mode and one lens position. Changing the focus, or the image's aspect ratio, needs a new one; [Stereo vision basics](./basics.md#calibration) says why.

## The ROS 2 path

`cameracalibrator`, the ROS 2 calibration tool, runs on a workstation in the `calibrator` service of `compose/local/`, reads the unit's raw camera images over Zenoh and shows its own window, with the same coverage bars. Its **COMMIT** sends each camera's calibration to that camera's `set_camera_info` service on the unit, which writes it where the dashboard does: the store, or the calibration path without one, with a refused calibration taken back. With a store, the unit takes the calibration once both sides' files are stored, a side stored by an earlier commit included: a **COMMIT** on one side alone pairs it with whatever the other side holds, so finish it on both sides. The dashboard's Current calibration part shows it once taken.

It needs the ROS 2 exporter, publishing the raw images (`publish_raw_images`, on by default), a Zenoh router both sides reach, and an X display; the steps are in [`compose/local/calibration_output/README.md`](../../compose/local/calibration_output/README.md). Use it when you want `cameracalibrator`'s saved samples; otherwise the dashboard needs none of this.

## A unit without a calibration

A unit with no calibration file for either camera, such as one for a new vehicle, starts its cameras alone and logs that it is uncalibrated. It computes no depth, and the camera settings are not offered on the dashboard: the cameras run with your composer's options. The dashboard's top bar reads **uncalibrated**, and the Calibration page says that depth starts once a calibration is applied.

Calibrate it from the page. When the unit takes the first calibration, it restarts with its pipeline, as it does on any apply from the page while its pipeline has stopped. A commit from `cameracalibrator` has the running pipeline reload the files, so it is refused on a unit whose pipeline does not run: calibrate such a unit from the page.

For a new vehicle, leave the calibration files out of `required_files/0` until you have them, or the build fails without them. A unit with only one side's file does not start its cameras at all: add the other side's file or remove the one there.

## See also

- [Stereo vision basics](./basics.md#calibration): what a calibration holds.
- [Vision API](./api.md#calibration): the calibration routes and channel.
- [Vision unit](./README.md#dashboard-and-api): the rest of the dashboard.
