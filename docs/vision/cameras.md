---
title: A camera of its own
description: Run a camera outside the stereo pair, choose the outputs it makes, calibrate it and measure its pose relative to the stereo pair.
---

Run a camera outside the stereo pair, for a view that is not a depth source. Declare it, choose its outputs, calibrate it and measure its pose. With a pose, the pipelines on it take distances from the stereo depth. You need a vision unit with a stereo pair ([Vision unit](./README.md)).

## Declare the camera

The `:camera` component runs one camera outside the stereo pair: `{:camera, name: :center, driver: VisionCore.Camera.V4L2Single, csiphy: 2}`.

- `:name` follows the rule of a detection pipeline's name, whose reserved names include `left`, `right` and `depth`. No camera shares a pipeline's name.
- The camera's frames are the output `{:camera_frame, name}`, which an exporter lists like the stereo cameras' (`{:camera_frame, :center}`).
- Each frame carries the optical frame `"<name>_optical"` unless you set `:frame_id`.
- A camera whose driver has named outputs makes each at every frame. `{:camera_frame, name, output}` names one, and `{:camera_frame, name}` is its first sent one, the default.

A `:driver` that is not a `VisionCore.Camera` raises `ArgumentError` as the unit starts, so a mistyped one fails the boot. A unit that fails later, such as one whose sensor never registers, stays down with the reason logged. The stereo unit and the rest of the vision core run on.

## Outputs

`VisionCore.Camera.V4L2Single` captures a Raspberry Pi HQ Camera (IMX477) on a CAMSS connector, Camera 2 on the VENTUNO Q ([The Arduino VENTUNO Q](./README.md#the-arduino-ventuno-q)). It takes the sensor's 2028 × 1520 12-bit binned mode as packed Bayer (pRCC). `v4l2_capture` demosaics it to 8-bit RGB in the camera's outputs. In the example below, one output is made only for the others, and one is sent as a JPEG:

```elixir
{:camera,
 name: :center,
 driver: VisionCore.Camera.V4L2Single,
 csiphy: 2,
 outputs: [
   view: [resolution: {2028, 1520}, processor: :cpu, send: false],
   view_jpeg: [from: :view, format: :jpeg, quality: 80],
   inference: [resolution: {1014, 760}, from: :view]
 ]}
```

Each output is made at every frame, so each path runs all the time, not only while someone watches it. An output takes these options:

| Option | Effect |
|---|---|
| `processor: :cpu` | `v4l2_capture`, this driver's only processor, converts the output from the sensor's frame. It converts at the mode's 2028 × 1520, or at 1014 × 760 with each 2 × 2 Bayer cell one pixel. Each such output converts the raw frame again. |
| `from:` | The output is averaged from another output in blocks, on the conversion's threads: each pixel is the mean of the block it covers. It is the cheap way to a second size. |
| `resolution:` | For an output made `from:` another, a whole fraction of its source's size, 2 × 2 here. Without it, the output has its source's size. |
| `format: :jpeg` | An output made `from:` another is that image, or its average, encoded by `v4l2_capture` with libjpeg-turbo. |
| `quality:` | The JPEG's quality, 1 to 100, 80 by default. |
| `send: false` | The output is still made at every frame, for the outputs made `from:` it, but `v4l2_capture` writes none of its frames. No consumer can take it. |

A 2 × 2 average of a `processor: :cpu` output is taken as each pair of rows is converted, while they are in the cache. Other blocks, and outputs of other outputs, are averaged after the conversion.

A JPEG output is encoded on a thread of its own, beside the one writing the frame's other outputs. The conversion does not wait for it. Its frames carry the JPEG, which the preview and the ROS 2 exporter send as it is. The image is encoded once a frame for both, and the core encodes none of it.

Each sent output crosses the Port at every frame: 9.2 MB a frame at 2028 × 1520, 2.3 MB at 1014 × 760. Here nothing takes the raw `view`, only its JPEG and its average, so `send: false` keeps it on the capture side. The unit's `VisionCore.Preview` encodes an RGB output only at the preview's rate, apart from the other previews, so its encode delays only its own stream.

`output: :full`, the default, and `output: :half` are the shorthand of one output, named as the value.

Each of these stops the camera's unit at start, saying why:

- a processor the driver lacks, or a resolution its processor cannot make;
- a `from:` that names no output, names a JPEG, or runs in a cycle;
- a size that is no whole fraction of its source's;
- a JPEG made by a processor;
- a `quality:` outside 1 to 100, or without `format: :jpeg`;
- an output with `send: false` that no output is made from;
- a name given twice.

Each consumer takes the camera's default output unless told otherwise:

| Consumer | Takes another output with |
|---|---|
| A pipeline | `source: {:camera, name, output}` |
| An exporter | `{:camera_frame, name, output}` |
| The ROS 2 exporter | `cameras: [outputs: [center: :view_jpeg]]` |
| The preview | its `outputs:` option, `preview: [outputs: [center: :view_jpeg]]` |
| The pose capture | `output:` |

A pipeline, an exporter or the ROS 2 exporter that names an output with `send: false` is refused at start, saying so. The pose capture answers `{:error, {:unsent_output, name, output}}`. The preview logs it and shows the camera's default.

## Colour and exposure

Auto exposure steers the green channel's mean. A grey-world white balance corrects the colour from the previous frame; `awb: false` applies `red_gain` and `blue_gain` as set instead.

The IMX477's colour follows libcamera's Raspberry Pi pipeline, with Raspberry Pi's tuning for the sensor. `v4l2_capture`:

1. subtracts the black level and applies the lens shading and white balance gains;
2. demosaics on linear 16-bit values;
3. applies the colour correction matrix of the colour temperature that the white balance gives;
4. blurs the colour at the 2 × 2 Bayer cells' resolution against high gain's coloured speckle, and keeps each pixel's brightness;
5. encodes the result to 8 bits through the tuning's contrast curve.

Auto exposure measures the green after lens shading and white balance, through the contrast curve, before the colour matrix and the denoise. `ccm: false` leaves the matrix out, and `denoise: false` the denoise. On this sensor `gamma` only sets how far auto exposure steps. On a sensor without a tuning, it also encodes the image.

`threads`, 1 to 8, sets how many threads convert each frame and average its outputs. Each thread takes a band of rows, and the image is the same whatever their number. Without it, a camera with a full-size output made by `:cpu` takes 3 threads, and otherwise 1.

## Worked example: the OVCS1 reference vehicle

`Ovcs1.Vision.Composer` runs a Raspberry Pi HQ Camera (IMX477) with a 3.6 mm lens on Camera 2, `:center`. It captures 2028 × 1520 in colour at 30 frames a second. That image, its `:view` output, is not sent. `v4l2_capture` makes two outputs from it:

- `:view_jpeg`, the image encoded once a frame, which the preview and ROS 2 show;
- `:inference`, the image averaged 2 × 2 to 1014 × 760. The unit runs YOLOX detection, the `:objects` pipeline, and FFNet road segmentation, the `:scene` pipeline, on it, on the NPU.

The models' inputs are smaller still, so the full image would cross to their Ports only to be shrunk there.

`priv/calibration/center.yaml` holds the camera's nominal calibration, from the lens and the pixel pitch, until it is calibrated. Until its pose is measured, its detections have no distance and its segmentation no road or off-road clouds. The same composer shape works on your own vehicle with your cameras and connectors.

## Calibration and pose

Three options of a camera's `:camera` component describe it to the rest of the unit. Its driver does not see them (`VisionCore.Camera.Unit`):

```elixir
{:camera,
 name: :center,
 driver: VisionCore.Camera.V4L2Single,
 csiphy: 2,
 calibration: Application.app_dir(:<vehicle>, "priv/calibration/center.yaml"),
 calibration_store_dir: "/data/vision/calibration",
 pose: Application.app_dir(:<vehicle>, "priv/calibration/center_pose.yaml")}
```

**`calibration:`** is the camera's `camera_info` YAML, as `cameracalibrator` writes it: K and D, `plumb_bob` or `equidistant` for a fisheye lens.

A calibration of another size than the frames is resampled to them, each pixel centre onto a pixel centre. For a 2 × 2 average, that is `fx / 2` and `(cx + ½) / 2 − ½`. One made at the sensor's full size therefore serves every output of the camera, each consumer at the size of the output it takes.

Frames of another aspect ratio, from a sensor mode that crops, see another part of the sensor. Until the camera is calibrated at that size, their camera info is empty and no stereo depth is projected into them, which is logged.

**`calibration_store_dir:`** is a writable directory. A calibration committed through `set_camera_info` is stored there as `camera_<name>.yaml` and takes precedence over `calibration:`, as for the stereo unit. It can be the stereo unit's directory, whose files are `<prefix>_left.yaml` and `<prefix>_right.yaml`.

The camera's `camera_info` and a segmentation pipeline's label `camera_info` take a committed calibration at once. A detection pipeline's boxes and a segmentation pipeline's clouds keep the calibration read at start until their unit restarts.

**`pose:`** is the camera's pose relative to the stereo pair. It is the transform from the rectified left optical frame, the frame of the depth, to the camera's optical frame. The transform is `p_camera = rotation × p_left + translation`, in metres (`VisionCore.Camera.Pose`). It holds while neither camera moves and the stereo pair keeps its calibration. A new stereo calibration changes the rectified frame, so measure the pose again.

## On ROS 2

The ROS 2 exporter's `cameras:` option publishes each camera of its own (`VisionCore.Ros2.Exporter`): every one by default, or those its `names:` lists. `<camera>` is the camera's name.

| Topic or service | Type | What |
|---|---|---|
| `<prefix>/<camera>/image_raw/compressed` | `sensor_msgs/CompressedImage` | The camera's image: an RGB or grey frame encoded to JPEG, at most `raw_image_max_hz` (10) a second; a JPEG frame as it arrives. |
| `<prefix>/<camera>/camera_info` | `sensor_msgs/CameraInfo` | Its K and D at the frame's size, R the identity and P = K with a zero column. |
| `<prefix>/<camera>/set_camera_info` | `sensor_msgs/srv/SetCameraInfo` | Stores a committed calibration, in `calibration_store_dir` or else over `calibration:`. |
| `/tf_static` | `tf2_msgs/TFMessage` | Its pose, from the stereo left camera's `frame_id` to the camera's, every second. The parent is the frame the depth is published in, in rectified coordinates: the rectified left camera, not the raw one. |

## Measure the pose

The pose comes from pictures of a chessboard that both the stereo left camera and the camera see. [`scripts/camera_pose.py`](../../scripts/camera_pose.py) solves it with OpenCV, holding both calibrations fixed.

> [!WARNING]
> Use a board whose inner corners are one odd and one even count, such as 9 × 6. A board such as 8 × 6 looks the same after a half turn. Two cameras turned far from each other can number its corners differently, which gives a wrong pose and a large error. The script refuses such a board unless you pass `--allow-symmetric`.

The commands below use the camera `center` and a 9 × 6 board of 25 mm squares. The unit is reached as `<vehicle>-vision.local`, and its `calibration_store_dir` is `/data/vision/calibration`. They work the same with your camera's name, board and store.

1. With the ROS 2 exporter publishing the camera (`cameras:`), start the calibrator on your workstation with the camera's name, as for the stereo pair:

   ```sh
   compose/local/scripts/calibrate.sh --camera center 9x6 0.025
   ```

   [`calibrate.sh`](../../compose/local/scripts/calibrate.sh) runs ROS 2's `cameracalibrator` in monocular mode, in the `calibrator` compose service. It reads `<prefix>/center/image_raw/compressed` (`CALIBRATION_TOPIC_PREFIX`, `stereo` by default), which the service decompresses. It passes the calibrator no camera-model option: the unit takes a `plumb_bob` or an `equidistant` calibration, whichever model it was made with.
2. Move the board until the calibrator's coverage bars fill.
3. Press CALIBRATE.
4. Press COMMIT. The camera's `set_camera_info` stores the calibration as `/data/vision/calibration/camera_center.yaml`. The camera's pipelines take it once the unit restarts ([Calibration and pose](#calibration-and-pose)).
5. Open the unit's IEx shell:

   ```sh
   ssh <vehicle>-vision.local
   ```

6. Hold the board still where both cameras see it whole, and record a pair:

   ```elixir
   VisionCore.Camera.PoseCapture.capture(:center)
   ```

   It answers `{:ok, %{left: path, camera: path, offset_ms: offset}}`. It writes the stereo left camera's raw frame and the camera's frame captured closest to it in time, within half a stereo pair period.

   They go to `/data/vision/pose_pairs/center/` as `left-<n>.png` and `camera-<n>.png`, numbered after the pairs already there. A JPEG output, such as the OVCS1 reference vehicle's default `:view_jpeg`, gives `camera-<n>.jpg`. When no two frames come that close, it answers `{:error, :no_matching_pair}`. `directory:` writes elsewhere, as on a workstation without `/data`.
7. Repeat step 6 for twenty poses or so, at several distances and tilts, with the board across the camera's image.
8. Copy the pairs and the calibrations the unit runs to your workstation. `stereo_left.yaml` is in the store only when the stereo pair's calibration was committed through `set_camera_info`. Otherwise the stereo unit runs `vehicles/<vehicle>/priv/calibration/stereo_left.yaml`: pass that one to the script instead of copying it.

   ```sh
   scp -r <vehicle>-vision.local:/data/vision/pose_pairs/center pairs
   scp <vehicle>-vision.local:/data/vision/calibration/camera_center.yaml .
   scp <vehicle>-vision.local:/data/vision/calibration/stereo_left.yaml .
   ```

9. Solve the pose on your workstation. The script needs OpenCV and NumPy, which the repository's pinned Python does not have. On Debian and Ubuntu, install `python3-opencv` and run it with the system Python. Elsewhere, run it with a Python that has the `opencv-python-headless` and `numpy` packages.

   ```sh
   /usr/bin/python3 -I scripts/camera_pose.py --pairs pairs \
       --left stereo_left.yaml --camera camera_center.yaml \
       --board 9x6 --square 0.025 \
       --output vehicles/<vehicle>/priv/calibration/center_pose.yaml
   ```

   It leaves out a pair in which it does not find the board in both images, and refuses images of several sizes. It ends with the RMS reprojection error:

   ```text
   <n> pairs, RMS reprojection error <error> px, pose written to vehicles/<vehicle>/priv/calibration/center_pose.yaml
   ```

   Under a pixel, the pose fits. Above, a pair is blurred or the board moved between the two captures. The script then lists each pair's error, worst first: record those pairs again, or leave them out with `--exclude <n>`.
10. Point the `:camera` component's `pose:` at the YAML in your vehicle package's `priv/calibration`.
11. Rebuild the unit and update it:

    ```sh
    ./ovcs build <vehicle> vision
    ./ovcs upload <vehicle> vision
    ```

    The ROS 2 exporter and each pipeline on the camera read the pose at start. Foxglove's 3D panel then places the camera's frame beside the stereo pair's. A detection pipeline on the camera places its boxes with the stereo depth ([Detect on a camera of its own](./detection.md#detect-on-a-camera-of-its-own)).

## See also

- [Object detection](./detection.md): detection pipelines on the camera.
- [Road segmentation](./segmentation.md): road and off-road points from the camera's image.
- [Vision channels](./channels.md#previews): the camera's preview channel.
