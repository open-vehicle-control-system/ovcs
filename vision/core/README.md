# vision_core

Stereo depth, object detection and road segmentation for a vehicle. Its exporters take them out of the unit, for example as ROS 2 messages over native Zenoh.

`vision_core` holds no vehicle knowledge. The vehicle package implements `VisionCore.Composer`, which returns a `VisionCore.Config` naming:

- the components to run: `:stereo`, `:camera`, `:detector`, `:hailo_detector`, `:qnn_detector`, `:segmenter` and `:qnn_segmenter` (`VisionCore.Components`);
- the exporters (`VisionCore.Exporter`, such as `VisionCore.Ros2.Exporter`);
- for ROS 2, the Zenoh router and the node name.

The detectors may be listed several times, each under its own `:name`, to run named detection pipelines (`VisionCore.Detection`). Each segmenter is named and segments the road on a camera of its own (`VisionCore.Segmentation`). `:camera` runs a camera of its own, previewed as `preview:<name>` (`VisionCore.Camera.Unit`).

`VisionCore.Application` starts the composer set in `:vision_core, :vehicle` under `VisionCore.Supervisor`: the saved parameters' storage and the parameter registry first, then the ROS 2 link when the configuration has one, the components, the exporters, and the dashboard's sources. With no composer it starts nothing.

On a vision target, compiling this app cross-builds the Ports from [`../rust`](../rust) through `Makefile` into `priv/`:

| Target | Ports |
|---|---|
| `rpi5` | `camera_capture`, `hailo_detect`, `jpeg_codec` and `stereo_match` |
| `okdo_c100` | `v4l2_capture` and `jpeg_codec` |
| `arduino_ventuno_q` | `v4l2_capture`, `jpeg_codec`, `qnn_detect` and `qnn_segment` |

The QNN Ports' bindings, the `qnn` crate's, are generated from the QAIRT archive `mise run fetch-qairt` caches.

The stereo stages (`VisionCore.Stereo.Pipeline.default_stages/1`) are written in Nx and compiled through `nx_iree`, for a Vulkan GPU or a CPU. The tests run them on EXLA and check them against OpenCV (evision, a test dependency); `--include vulkan` also runs them on the host's Vulkan devices, `--include iree` compiles them with IREE. The first build compiles the IREE runtime with CMake. With `compute: :native` the stages run natively in the `stereo_match` Port instead (`VisionCore.Stereo.NativeSegment`), whose tests compare each stage with its Nx implementation on the same inputs: on Nx's evaluator, bit for bit, and the disparity with `NxStereo.sgm/3` on EXLA.

The vision unit as a whole is described in [Vision unit](../../docs/vision/README.md).

```sh
mix deps.get
mix test
mix credo --strict
```
