# vision_core

Stereo depth and object detection for a vehicle, taken out of the unit by its exporters, such as ROS 2 messages over native Zenoh.

`vision_core` holds no vehicle knowledge. The vehicle package implements `VisionCore.Composer`, which returns a `VisionCore.Config` naming the components to run (`:stereo`, `:camera`, `:detector`, `:hailo_detector`, `:qnn_detector`; the detectors may be listed several times under their own `:name` to run named detection pipelines, and `:camera` runs a camera of its own, previewed as `preview:<name>`; see `VisionCore.Components`, `VisionCore.Camera.Unit` and `VisionCore.Detection`), the exporters (`VisionCore.Exporter`, such as `VisionCore.Ros2.Exporter`) and, for ROS 2, the Zenoh router and the node name.

`VisionCore.Application` starts the composer set in `:vision_core, :vehicle` under `VisionCore.Supervisor`: the saved parameters' storage and the parameter registry first, then the ROS 2 link when the configuration has one, the components, the exporters, and the dashboard's sources. With no composer it starts nothing.

On a vision target, compiling this app cross-builds the Ports from [`../rust`](../rust) through `Makefile` into `priv/`: `camera_capture`, `hailo_detect`, `jpeg_codec` and `stereo_match` on `rpi5`, `v4l2_capture` and `jpeg_codec` on `okdo_c100`, and those two with `qnn_detect` on `arduino_ventuno_q`, whose QNN bindings are generated from the QAIRT archive `mise run fetch-qairt` caches.

The stereo stages (`VisionCore.Stereo.Pipeline.default_stages/1`) are written in Nx and compiled through `nx_iree`, for a Vulkan GPU or a CPU. The tests run them on EXLA and check them against OpenCV (evision, a test dependency); `--include vulkan` also runs them on the host's Vulkan devices, `--include iree` compiles them with IREE. The first build compiles the IREE runtime with CMake. With `compute: :native` the stages run natively in the `stereo_match` Port instead (`VisionCore.Stereo.NativeSegment`), whose tests compare each stage with its Nx implementation on the same inputs: on Nx's evaluator, bit for bit, and the disparity with `NxStereo.sgm/3` on EXLA.

The vision unit as a whole is described in [Vision unit](../../docs/vision/README.md).

```sh
mix deps.get
mix test
mix credo --strict
```
