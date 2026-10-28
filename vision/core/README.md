# vision_core

Stereo depth and object detection for a vehicle, published over native Zenoh as ROS 2 messages.

`vision_core` holds no vehicle knowledge. The vehicle package implements `VisionCore.Composer`, which returns a `VisionCore.Config` naming the Zenoh router, the node name and the components to run (`:heartbeat`, `:simulator_clock`, `:stereo`, `:detector`, `:hailo_detector`; see `VisionCore.Components`).

`VisionCore.Application` starts the composer set in `:vision_core, :vehicle` under `VisionCore.Supervisor`, with `VisionCore.Ros2.ZenohClient` first. With no composer it starts nothing.

On the `rpi5` target, compiling this app cross-builds the `camera_capture` and `hailo_detect` Ports from [`../rust`](../rust) through `Makefile` into `priv/`.

The vision unit as a whole is described in [Vision unit](../../docs/vision.md).

```sh
mix deps.get
mix test
mix credo --strict
```
