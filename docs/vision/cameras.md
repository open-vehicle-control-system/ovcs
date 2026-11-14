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
- A camera whose driver has named outputs makes each at every frame. `{:camera_frame, name, output}` names one, and `{:camera_frame, name}` is its first sent image output, the default.

A `:driver` that is not a `VisionCore.Camera` raises `ArgumentError` as the unit starts, so a mistyped one fails the boot. A camera whose sensor has not registered yet, or whose capture program exits, keeps its unit running: the driver tries again after 1 s, then 2, 5, 10 and 30 s, each failure logged, and the status reports the camera absent meanwhile. A unit that fails to start, or whose processes keep crashing, is down with the reason logged, and is started again once a minute. The stereo unit and the rest of the vision core run on.

## Outputs

`VisionCore.Camera.V4L2Single` captures a Raspberry Pi HQ Camera (IMX477) on a CAMSS connector, Camera 2 on the VENTUNO Q ([The Arduino VENTUNO Q](./README.md#the-arduino-ventuno-q)). It takes the sensor's 2028 × 1520 12-bit binned mode as packed Bayer (pRCC). `v4l2_capture` demosaics it to 8-bit RGB in the camera's outputs. In the example below, one output is made only for the others, one is sent as H.264, one averaged to half its size, and that half sent as a JPEG:

```elixir
{:camera,
 name: :center,
 driver: VisionCore.Camera.V4L2Single,
 csiphy: 2,
 outputs: [
   full: [resolution: {2028, 1520}, processor: :cpu, send: false],
   half: [resolution: {1014, 760}, from: :full],
   half_jpeg: [from: :half, format: :jpeg, quality: 80],
   full_h264: [from: :full, format: :h264, bitrate_kbps: 8_000, keyframe_interval: 30]
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
| `format: :h264` | An output made `from:` another is that image, or its average, encoded as an H.264 stream on the board's video encoder. Its width and height are even. |
| `bitrate_kbps:` | The stream's constant bitrate in kilobits a second, 1 to 2000000. Required with `format: :h264`. |
| `keyframe_interval:` | The frames from one key frame to the next. A viewer that joins the stream starts at the next key frame. Required with `format: :h264`. |
| `send: false` | The output is still made at every frame, for the outputs made `from:` it, but `v4l2_capture` writes none of its frames. No consumer can take it. |

A 2 × 2 average of a `processor: :cpu` output is taken as each pair of rows is converted, while they are in the cache. Other blocks, and outputs of other outputs, are averaged after the conversion.

A JPEG output is encoded on a thread of its own, beside the one writing the frame's other outputs. The conversion does not wait for it. Its frames carry the JPEG, which the preview and the ROS 2 exporter send as it is. The image is encoded once a frame for both, and the core encodes none of it.

An H.264 output is converted to NV12 on the conversion's threads and encoded on a thread of its own, on a V4L2 memory-to-memory encoder: Qualcomm's Iris (`qcom-iris-encoder`) on the VENTUNO Q. Each frame of the stream crosses the Port as one record, its key frame flag beside it, and every key frame carries the stream's parameter sets.

> [!WARNING]
> The encoder needs the firmware `qcom/vpu/vpu30_p4_s6.mbn`. On a board without an encoder or its firmware, `v4l2_capture` stops at start, and the camera's unit with it: none of the camera's outputs run.

An H.264 output is a video, not an image. A decoder needs every frame from a key frame on, so its consumers take every frame in order, where an image's take the newest. Only the consumers of videos take it:

| Consumer | Takes the video with |
|---|---|
| An exporter | `{:camera_video, name, output}`, every frame in order from a key frame, without `max_hz` |
| The ROS 2 exporter | `cameras: [videos: [center: :full_h264]]` |
| The dashboard | `preview: [videos: [center: :full_h264]]`, in place of the camera's JPEG preview, decoded in the browser, which needs HTTPS ([Video](./channels.md#video)) |

A pipeline, an exporter or the preview that names an H.264 output as an image is refused, as for an output with `send: false`.

Each sent output crosses the Port at every frame: 9.2 MB a frame at 2028 × 1520, 2.3 MB at 1014 × 760. Here nothing takes the raw `full`, only its video and its average, so `send: false` keeps it on the capture side. The unit's `VisionCore.Preview` encodes an RGB output only at the preview's rate, apart from the other previews, so its encode delays only its own stream.

`output: :full`, the default, and `output: :half` are the shorthand of one output, named as the value.

Each of these stops the camera's unit at start, saying why:

- a processor the driver lacks, or a resolution its processor cannot make;
- a `from:` that names no output, names a JPEG or an H.264 output, or runs in a cycle;
- a size that is no whole fraction of its source's;
- a JPEG or an H.264 output made by a processor;
- a `quality:` outside 1 to 100, or without `format: :jpeg`;
- a `bitrate_kbps:` or a `keyframe_interval:` missing, out of range, or without `format: :h264`;
- an H.264 output of an odd width or height;
- an output with `send: false` that no output is made from;
- a name given twice.

Each consumer takes the camera's default output unless told otherwise:

| Consumer | Takes another output with |
|---|---|
| A pipeline | `source: {:camera, name, output}` |
| An exporter | `{:camera_frame, name, output}` |
| The ROS 2 exporter | `cameras: [outputs: [center: :half_jpeg]]` |
| The preview | its `outputs:` option, `preview: [outputs: [center: :half_jpeg]]` |

The calibration page always looks for the board in the camera's default output.

A pipeline, an exporter or the ROS 2 exporter that names an output with `send: false` is refused at start, saying so. The preview logs it and shows the camera's default.

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

On a processor whose cores differ in speed, such as the VENTUNO Q's Cortex-A78 and Cortex-A55, every thread of the camera's `v4l2_capture` runs on the cores faster than the slowest, from the kernel's `cpu_capacity`. A frame waits for its last band, so one band on a slow core holds the whole frame back.

## Parameters

A camera whose driver has runtime controls, as `VisionCore.Camera.V4L2Single` has, lists them as vision parameters, `<name>.camera.<control>`. They change while the camera captures ([Change a parameter](./api.md#change-a-parameter)), and a saved value is applied again each time the camera starts. A control given in the `:camera` component is the value the camera starts with.

| Parameter | Values | Meaning |
|---|---|---|
| `rotation` | 0 or 180 | Image rotation in degrees. |
| `auto_exposure` | on or off | Automatic exposure. On, it sets `exposure_us` and `analogue_gain`. |
| `exposure_us` | 100 to 1000000 | Exposure time in µs: fixed, or where auto exposure starts. |
| `analogue_gain` | 1 to 16 | Analogue gain: fixed, or where auto exposure starts. |
| `target_brightness` | 1 to 254 | Mean green auto exposure steers the image to. |
| `max_exposure_us` | 100 to 1000000 | Longest exposure auto exposure uses before it raises the gain. |
| `max_gain` | 1 to 16 | Highest analogue gain auto exposure uses. |
| `black_level` | 0 to 4094 | Raw sample value of black. |
| `gamma` | 0.5 to 4 | Gamma of the image, or of auto exposure's steps on a sensor with a tuning. |
| `awb` | on or off | Automatic white balance. On, it sets `red_gain` and `blue_gain`. |
| `red_gain`, `blue_gain` | 0.5 to 4 | Colour gains while the white balance is off. |
| `ccm` | on or off | The tuning's colour correction matrix. |
| `denoise` | on or off | The chroma denoise. |
| `threads` | 1 to 8 | Threads converting each frame. |

While `auto_exposure` is on, `exposure_us` and `analogue_gain` read what the sensor applies, and a change to them is refused. The same holds for the colour gains under `awb`, which read the gains the white balance applies. Switching either mode off keeps the values it applied.

`max_exposure_us` and `max_gain` hold at once: lowered, auto exposure brings the exposure and gain within them, and keeps the brightness as far as they allow. Raised, they change nothing until the image moves away from its target.

The frame rate, the sensor mode and each output, with its size and its format's quality or bitrate, are listed after them as `fps`, `sensor_mode` and `output_<name>`. They are fixed when the camera starts: change them in your composer.

## Worked example: the OVCS1 reference vehicle

`Ovcs1.Vision.Composer` runs a Raspberry Pi HQ Camera (IMX477) with a 3.6 mm lens on Camera 2, `:center`. It captures 2028 × 1520 in colour at 30 frames a second. That image, its `:full` output, is not sent. `v4l2_capture` makes three outputs from it:

- `:full_h264`, the image encoded as H.264 at 8000 kbps with a key frame every 30 frames, the camera's video, which the dashboard shows and ROS 2 publishes;
- `:half`, the image averaged 2 × 2 to 1014 × 760, the camera's default. The unit runs YOLOX detection, the `:objects` pipeline, and FFNet road segmentation, the `:scene` pipeline, on it, on the NPU;
- `:half_jpeg`, the half image encoded once a frame, which ROS 2 publishes as the camera's image.

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

The camera's `camera_info`, a segmentation pipeline's label `camera_info`, a detection pipeline's boxes and a segmentation pipeline's clouds take a committed calibration at once, without a restart.

**`pose:`** is the camera's built-in pose relative to the stereo pair. It is the transform from the rectified left optical frame, the frame of the depth, to the camera's optical frame. The transform is `p_camera = rotation × p_left + translation`, in metres (`VisionCore.Camera.Pose`). A pose measured on the dashboard is stored in `calibration_store_dir` as `camera_<name>_pose.yaml` and takes precedence over `pose:` ([Measure the pose](#measure-the-pose)). The pipelines on the camera and the ROS 2 exporter take a measured pose at once, without a restart. A pose holds while neither camera moves and the stereo pair keeps its calibration. A new stereo calibration changes the rectified frame, so measure the pose again.

## On ROS 2

The ROS 2 exporter's `cameras:` option publishes each camera of its own (`VisionCore.Ros2.Exporter`): every one by default, or those its `names:` lists. `<camera>` is the camera's name, the namespace of its topics; `topic_prefix:` in `cameras:` puts them under `<topic_prefix>/<camera>/` instead. On the OVCS1 reference vehicle, the camera `center` publishes `/center/image_raw/compressed`. [What leaves the unit](./data_flow.md#what-leaves-the-unit) lists every topic of the unit.

| Topic or service | Type | What |
|---|---|---|
| `<camera>/image_raw/compressed` | `sensor_msgs/CompressedImage` | The camera's image: an RGB or grey frame encoded to JPEG, at most `raw_image_max_hz` (10) a second; a JPEG frame as it arrives. |
| `<camera>/camera_info` | `sensor_msgs/CameraInfo` | Its K and D at the frame's size, R the identity and P = K with a zero column. |
| `<camera>/image_raw/h264` | `foxglove_msgs/CompressedVideo` | With `videos:`, each frame of the camera's H.264 output, format `h264`, its NAL units in Annex B form. Foxglove's Image panel decodes it. It needs `ros-<distro>-foxglove-msgs` on the ROS side. |
| `<camera>/exposure_us`, `<camera>/analogue_gain` | `std_msgs/Float64` | Five times a second, the exposure in microseconds and the analogue gain the camera applied, when its driver reports them, as `VisionCore.Camera.V4L2Single` does. |
| `<camera>/set_camera_info` | `sensor_msgs/srv/SetCameraInfo` | Stores a committed calibration, in `calibration_store_dir` or else over `calibration:`. |
| `/tf_static` | `tf2_msgs/TFMessage` | Its pose, from the stereo left camera's `frame_id` to the camera's, every second. The parent is the frame the depth is published in, in rectified coordinates: the rectified left camera, not the raw one. |

## Measure the pose

The pose comes from views of a chessboard that both the stereo left camera and the camera see. The dashboard's Calibration page solves it on the unit with OpenCV, holding both cameras' calibrations fixed. You need the stereo pair and the camera calibrated first ([Calibrate the cameras](./calibration.md)), and a printed board on a rigid plate.

> [!WARNING]
> Use a board whose inner corners are one odd and one even count, such as 9 × 6. A board such as 8 × 6 looks the same after a half turn. Two cameras turned far from each other can number its corners differently, which gives a wrong pose and a large error. The page warns of such a board.

The steps use the OVCS1 reference vehicle's camera `center`; they work the same with your camera's name.

1. Open the dashboard and choose **Position** under **Center camera** in the menu's **Cameras** section, or go to `?calibration=center-pose`. The page shows the pose in use: where the camera sits from the left camera, how far and how it is turned, then its rotation and translation. Without a pose it reads **Not measured**.
2. Press **Calibrate**, enter the board and press **Start capturing**. A session is refused while the stereo pair or the camera has no calibration, naming the one to make first. Both calibrations must be `plumb_bob`, as the page makes them: the page refuses an `equidistant` one.
3. Hold the board still where both cameras see it whole, then move it to the next place. Both previews show the corners found. A view counts when both cameras see the whole board, in frames captured within half a stereo pair period of each other: a board that moves between the two gives a large error. The four gauges follow the coverage in the camera's image.
4. Press **Compute calibration** once the gauges are full, or at 40 views kept. A camera that sees wider than the left camera, such as the OVCS1 reference vehicle's center camera, sees the board both see only in the middle of its image, so its X and Y gauges may stay short. The result shows the reprojection error, with the verdicts of a calibration, and where the camera sits from the left camera, in millimetres.
5. Check that position against a ruler. On the OVCS1 reference vehicle the center camera sits between the two stereo cameras, about half the baseline to the right of the left one, in their plane. A large error usually means a board that moved between the two frames of a view, or that bent. A position far from the ruler's usually means a wrong square size.
6. Press **Use this calibration**. The unit stores the pose as `camera_center_pose.yaml` in the camera's `calibration_store_dir`, or over its `pose:` file without a store.

The pipelines on the camera and the ROS 2 exporter take the new pose at once, without a restart. A detection pipeline on the camera then places its boxes with the stereo depth ([Detect on a camera of its own](./detection.md#detect-on-a-camera-of-its-own)), and Foxglove's 3D panel places the camera's frame beside the stereo pair's.

The unit keeps every pose it was given, as it keeps calibrations ([The calibrations kept](./calibration.md#the-calibrations-kept)). To ship one in your vehicle package, **Download** it as `<camera>_pose.yaml`, put it in `vehicles/<vehicle>/priv/calibration/` and point the `:camera` component's `pose:` at it.

## See also

- [Object detection](./detection.md): detection pipelines on the camera.
- [Road segmentation](./segmentation.md): road and off-road points from the camera's image.
- [Vision channels](./channels.md#previews): the camera's preview channel.
