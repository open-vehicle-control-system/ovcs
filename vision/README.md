# vision

The vision unit: stereo depth and object detection on a single board, published as ROS 2 messages over Zenoh, with its own dashboard. The guide is [Vision unit](../docs/vision.md).

| Path | What it is |
|---|---|
| [`core`](./core/README.md) | `vision_core`: camera drivers, rectification, stereo matching, detection and the ROS publishers |
| [`api`](./api/README.md) | `vision_api`: the Phoenix endpoint and channels behind the dashboard |
| [`firmware`](./firmware/README.md) | `vision_firmware`: the Nerves image |
| [`dashboard`](./dashboard/README.md) | The Vue dashboard: previews, status, parameters and settings |
| [`rust`](./rust/README.md) | The capture and inference programs `vision_core` runs as Ports |

## Boards

| Target | Board | Capture | Stereo matching | Detection |
|---|---|---|---|---|
| `rpi5` | Raspberry Pi 5 with a Hailo-8 | libcamera, frames synced by the Pi's camera sync | `nx_stereo` on the CPU | HailoRT |
| `okdo_c100` | OKdo Nano C100 (Jetson Nano module) | raw V4L2, right sensor phase-locked to the left | `nx_stereo` on the GPU (Vulkan) | none yet |

A vehicle picks the board with `vision_target/0`, and the capture driver, the stereo stages' options and the compiler options for its board in its vision composer.

## Libraries

### Elixir

| Library | Used for |
|---|---|
| [Nx](https://github.com/elixir-nx/nx) | Tensors, and the Nx stereo stages: resizing, rectification, matching, filtering, depth and the point cloud. |
| [nx_stereo](https://github.com/Spin42/nx_stereo) | Stereo in Nx: semi-global matching (libSGM's algorithm, with its stages as precompiled Vulkan compute shaders), rectification, area resizing, the median filter, depth, the point cloud and the turbo colour map. |
| [nx_iree](https://github.com/Spin42/nx_iree) | Compiles Nx functions with IREE and runs them through IREE's runtime, on Vulkan (C100) or the CPU (Pi 5). Functions for the device are compiled on a host into a module cache, so the device needs neither EXLA nor the IREE compiler. |
| [EXLA](https://github.com/elixir-nx/nx/tree/main/exla) | Development and tests only: runs the Nx stages on the CPU in tests, and lowers Nx functions for `nx_iree` when the module cache is built. |
| [evision](https://github.com/cocoa-xu/evision) | Tests only: OpenCV, the reference the Nx stages are checked against. |
| [`ros2_zenoh`](../libraries/ros2_zenoh/README.md) | The ROS 2 message types, their CDR encoding and `rmw_zenoh`'s key expressions and attachments, shared with `ros_bridge`. |
| [zenohex](https://github.com/biyooon-ex/zenohex) | Zenoh from Elixir: publishes and subscribes ROS 2 topics through the router `rmw_zenoh` uses. |
| [yaml_elixir](https://github.com/KrisKennaway/yaml-elixir) | Reads the camera calibration files. |
| [Phoenix](https://www.phoenixframework.org/), [Bandit](https://github.com/mtrudel/bandit) | The API: the HTTP endpoint, `/api/settings` and the preview channels. |
| [Nerves](https://nerves-project.org/) | The firmware image, on `ovcs_bridges_system_rpi5` or `nerves_system_okdo_c100`. |

### Rust

| Library | Used for |
|---|---|
| [libcamera-rs](https://github.com/lit-robotics/libcamera-rs) | `camera_capture` on the Pi: the camera pipeline, its controls and the Pi's camera sync. |
| [TurboJPEG](https://libjpeg-turbo.org/) | `camera_capture`: JPEG encoding of each frame, over FFI. |
| [HailoRT](https://github.com/hailo-ai/hailort) | `hailo_detect`: inference on the Hailo-8, through its C API (bindgen). |
| [libc](https://github.com/rust-lang/libc) | `v4l2_capture` on the C100: the V4L2 ioctls, mmap and poll. |

### Dashboard

[Vue 3](https://vuejs.org/), [Pinia](https://pinia.vuejs.org/) for its state, the [Phoenix](https://hexdocs.pm/phoenix/js/) JavaScript client for the channels, built with [Vite](https://vite.dev/).
