# vision/rust

Cargo workspace of the programs `vision_core` runs as Ports.

| Crate | What it does |
|---|---|
| `camera_capture` | Captures frames through libcamera and writes them as JPEG records or, with `--format grey`, as grey records of their luma |
| `hailo_detect` | Runs a compiled model on a Hailo accelerator through HailoRT and writes detections |
| `v4l2_capture` | Captures the OKdo Nano C100's two CSI cameras over raw V4L2, locks the right sensor's frame starts to the left one's by adjusting its vertical blanking, holds both lens actuators at the `focus` setting when the system drives them, and writes grey frame pairs |
| `jpeg_codec` | Encodes grey or RGB images as JPEG, colours depth previews, and decodes JPEG frames to grey, for `VisionCore.Jpeg` |
| `stereo_match` | Computes the stereo pipeline's stages on the CPU, on every core, with the results of their Nx implementations, the disparity among them, for `VisionCore.Stereo.Matcher` |
| `framing` | The `{:packet, 4}` framing the binaries share: a big-endian length prefix, little-endian scalars |

The Elixir side of the protocol is `VisionCore.Camera.LibCamera`, `VisionCore.Detection.Backend.Hailo`, `VisionCore.Camera.V4L2`, `VisionCore.Jpeg` and `VisionCore.Stereo.Matcher`.

The `device` feature of `camera_capture` and `hailo_detect` links the device libraries: libcamera from the system, `libhailort` from [`libraries/hailort`](../../libraries/hailort), whose header and library directories `../core/Makefile` passes as `HAILORT_INCLUDE_DIR` and `HAILORT_LINK_DIR`. Without it the crates build on any host, which is what the unit tests use:

```sh
cargo test --workspace
```

For the `rpi5` Nerves target, `../core/Makefile` runs the cross-build, for the Cortex-A76, and installs `camera_capture`, `hailo_detect`, `jpeg_codec` and `stereo_match` into `vision_core`'s `priv/`; for `okdo_c100` it installs `v4l2_capture`, which needs only libc, and `jpeg_codec`. The `vision_core` tests build `jpeg_codec` and `stereo_match` for the host themselves, and check `stereo_match` against `NxStereo.sgm/3`. It needs the `aarch64-unknown-linux-gnu` Rust target (`mise install`) and a host libclang for bindgen.

`stereo_match` keeps a configured segment of stages per pipeline (`VisionCore.Stereo.NativeSegment`), with what its stages carry from one pair to the next, and runs a pair through all of them in one request; the protocol is in `stereo_match/src/protocol.rs`. It reads the next request and writes the previous reply on threads of their own while it computes, and computes on a pool of threads kept from one request to the next. Its unit tests check the matching against a step-by-step transcription of `NxStereo.sgm/3`; `vision_core`'s tests check every stage against its Nx implementation. To time the matching on the machine at hand, at a size, disparities, paths, threads and runs of your choice:

```sh
cargo run --release --example bench -p stereo_match -- 480 360 64 3 4 30
```
