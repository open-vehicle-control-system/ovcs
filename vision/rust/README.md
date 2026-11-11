# vision/rust

Cargo workspace of the programs `vision_core` runs as Ports.

| Crate | What it does |
|---|---|
| `camera_capture` | Captures frames through libcamera and writes them as JPEG records or, with `--format grey`, as grey records of their luma |
| `hailo_detect` | Runs a compiled model on a Hailo accelerator through HailoRT and writes detections |
| `qnn_detect` | Runs a model's QNN context binary on a Qualcomm Hexagon NPU and writes detections, YOLOX's boxes decoded |
| `detection` | Library the detection Ports share: their record protocol, the letterbox between the caller's image and the model's input, and non-maximum suppression |
| `v4l2_capture` | Captures two CSI cameras over raw V4L2, on the OKdo Nano C100 or, through CAMSS in packed 10-bit Bayer, on the Arduino VENTUNO Q, locks the right sensor's frame starts to the left one's by adjusting its vertical blanking, holds both lens actuators at the `focus` setting when the system drives them, and writes grey frame pairs; given one capture node and sensor (`--video`, `--sensor`), it captures that camera alone, such as the IMX477 on the VENTUNO Q in packed 12-bit Bayer, and writes RGB frames with grey-world white balance, demosaiced bilinearly at the capture's size or, with `--output half`, 2×2 at half of it; for the IMX477 it follows libcamera's Raspberry Pi pipeline with Raspberry Pi's tuning (lens shading, colour correction matrix and contrast curve of the colour temperature, auto exposure measuring the green after lens shading through the curve; the `ccm=false` setting leaves the matrix out), other sensors take the plain `gamma`. `v4l2_capture/libcamera_tuning.py` writes a sensor's tuning module from libcamera's tuning file |
| `jpeg_codec` | Encodes grey or RGB images as JPEG, colours depth previews, and decodes JPEG frames to grey, for `VisionCore.Jpeg` |
| `framing` | The `{:packet, 4}` framing the binaries share: a big-endian length prefix, little-endian scalars |

The Elixir side of the protocol is `VisionCore.Camera.LibCamera`, `VisionCore.Detection.Backend.Hailo`, `VisionCore.Detection.Backend.Qnn`, `VisionCore.Camera.V4L2` and `VisionCore.Jpeg`. The stereo stages' native Port, `stereo_match`, is nx_stereo's: it builds it when it compiles.

The `device` feature of `camera_capture` and `hailo_detect` links the device libraries: libcamera from the system, `libhailort` from [`libraries/hailort`](../../libraries/hailort), whose header and library directories `../core/Makefile` passes as `HAILORT_INCLUDE_DIR` and `HAILORT_LINK_DIR`. Without it the crates build on any host, all but `qnn_detect`, which is what the unit tests use:

```sh
cargo test
```

For the `rpi5` Nerves target, `../core/Makefile` runs the cross-build, for the Cortex-A76, and installs `camera_capture`, `hailo_detect` and `jpeg_codec` into `vision_core`'s `priv/`; for `okdo_c100` it installs `v4l2_capture`, which needs only libc, and `jpeg_codec`; for `arduino_ventuno_q`, for the Cortex-A78, those two and `qnn_detect`. `qnn_detect` is outside the workspace's default members: its bindings are generated with bindgen from the QNN headers of the QAIRT archive `mise run fetch-qairt` caches, which the Makefile extracts, and nothing derived from them is committed. Its unit tests need those headers too: `QAIRT_INCLUDE_DIR=<qairt>/include/QNN cargo test -p qnn_detect --lib`. The `vision_core` tests build `jpeg_codec` for the host themselves. The workspace needs the `aarch64-unknown-linux-gnu` Rust target (`mise install`) and a host libclang for bindgen.
