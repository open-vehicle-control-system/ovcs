# vision/rust

Cargo workspace of the programs `vision_core` runs as Ports.

| Crate | What it does |
|---|---|
| `camera_capture` | Captures frames through libcamera and writes them as JPEG records |
| `hailo_detect` | Runs a compiled model on a Hailo accelerator through HailoRT and writes detections |
| `v4l2_capture` | Captures the OKdo Nano C100's two CSI cameras over raw V4L2, locks the right sensor's frame starts to the left one's by adjusting its vertical blanking, holds both lens actuators at the `focus` setting when the system drives them, and writes grey frame pairs |
| `jpeg_codec` | Encodes grey or RGB images as JPEG, colours depth previews, and decodes JPEG frames to grey, for `VisionCore.Jpeg` |
| `framing` | The `{:packet, 4}` framing the binaries share: a big-endian length prefix, little-endian scalars |

The Elixir side of the protocol is `VisionCore.Camera.LibCamera`, `VisionCore.Detection.Backend.Hailo` and `VisionCore.Camera.V4L2`.

The `device` feature of `camera_capture` and `hailo_detect` links the device libraries: libcamera from the system, `libhailort` from [`libraries/hailort`](../../libraries/hailort), whose header and library directories `../core/Makefile` passes as `HAILORT_INCLUDE_DIR` and `HAILORT_LINK_DIR`. Without it the crates build on any host, which is what the unit tests use:

```sh
cargo test --workspace
```

For the `rpi5` Nerves target, `../core/Makefile` runs the cross-build and installs `camera_capture`, `hailo_detect` and `jpeg_codec` into `vision_core`'s `priv/`; for `okdo_c100` it installs `v4l2_capture`, which needs only libc, and `jpeg_codec`. The `vision_core` tests build `jpeg_codec` for the host themselves. It needs the `aarch64-unknown-linux-gnu` Rust target (`mise install`) and a host libclang for bindgen.
