# vision/rust

Cargo workspace of the programs `vision_core` runs as Ports.

| Crate | What it does |
|---|---|
| `camera_capture` | Captures frames through libcamera and writes them as JPEG records |
| `hailo_detect` | Runs a compiled model on a Hailo accelerator through HailoRT and writes detections |
| `framing` | The `{:packet, 4}` framing both binaries share: a big-endian length prefix, little-endian scalars |

The Elixir side of the protocol is `VisionCore.Camera.LibCamera` and `VisionCore.Inference.Hailo`.

The `device` feature of `camera_capture` and `hailo_detect` links the device libraries: libcamera from the system, `libhailort` from [`libraries/hailort`](../../libraries/hailort), whose header and library directories `../core/Makefile` passes as `HAILORT_INCLUDE_DIR` and `HAILORT_LINK_DIR`. Without it the crates build on any host, which is what the unit tests use:

```sh
cargo test --workspace
```

For the `rpi5` Nerves target, `../core/Makefile` runs the cross-build and installs both binaries into `vision_core`'s `priv/`. It needs the `aarch64-unknown-linux-gnu` Rust target (`mise install`) and a host libclang for bindgen.
