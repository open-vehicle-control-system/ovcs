# vision_core

Stereo depth and object detection for a vehicle, published over native Zenoh as ROS 2 messages.

`vision_core` holds no vehicle knowledge. The vehicle package implements `VisionCore.Composer`, which returns a `VisionCore.Config` naming the Zenoh router, the node name and the components to run (`:heartbeat`, `:simulator_clock`, `:stereo`, `:detector`, `:hailo_detector`; see `VisionCore.Components`).

`VisionCore.Application` starts the composer set in `:vision_core, :vehicle` under `VisionCore.Supervisor`, with `VisionCore.Ros2.ZenohClient` first. With no composer it starts nothing.

On a vision target, compiling this app cross-builds the Ports from [`../rust`](../rust) through `Makefile` into `priv/`: `camera_capture`, `hailo_detect`, `jpeg_codec` and `stereo_match` on `rpi5`, `v4l2_capture` and `jpeg_codec` on `okdo_c100`.

The stereo stages (`VisionCore.Stereo.Pipeline.default_stages/1`) are written in Nx and compiled through `nx_iree`, for a Vulkan GPU or a CPU. The tests run them on EXLA and check them against OpenCV (evision, a test dependency); `--include vulkan` also runs them on the host's Vulkan devices, `--include iree` compiles them with IREE. The first build compiles the IREE runtime with CMake. With `compute: :native` the stages run natively in the `stereo_match` Port instead (`VisionCore.Stereo.NativeSegment`), whose tests compare each stage with its Nx implementation on the same inputs: on Nx's evaluator, bit for bit, and the disparity with `NxStereo.sgm/3` on EXLA.

The vision unit as a whole is described in [Vision unit](../../docs/vision.md).

```sh
mix deps.get
mix test
mix credo --strict
```
