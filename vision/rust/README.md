# vision/rust

Cargo workspace of the programs `vision_core` runs as Ports.

| Crate | What it does |
|---|---|
| `camera_capture` | Captures frames through libcamera and writes them as JPEG records or, with `--format grey`, as grey records of their luma |
| `hailo_detect` | Runs a compiled model on a Hailo accelerator through HailoRT and writes detections |
| `qnn_detect` | Runs a model's QNN context binary on a Qualcomm Hexagon NPU and writes detections, YOLOX's boxes decoded. Its statistics line, every minute, gives each stage's mean time per request: waiting (`idle`), reading, the letterbox, the execution's stages (`qnn`), decoding and the reply |
| `qnn_segment` | Runs a semantic segmentation model's QNN context binary on a Qualcomm Hexagon NPU, over a band of an RGB image resized to the model's input. It writes each output cell's class. Its statistics line, every minute, gives each stage's mean time per request: waiting (`idle`), reading, the resize, the execution's stages (`qnn`), argmax and the reply |
| `qnn` | Library the QNN Ports share ([`qnn`](#qnn)) |
| `detection` | Library the detection Ports share: their record protocol, the letterbox between the caller's image and the model's input, and non-maximum suppression. `qnn_segment` shares its bilinear resize |
| `v4l2_capture` | Captures two CSI cameras over raw V4L2, on the OKdo Nano C100 or, through CAMSS in packed 10-bit Bayer, on the Arduino VENTUNO Q, locks the right sensor's frame starts to the left one's by adjusting its vertical blanking, holds both lens actuators at the `focus` setting when the system drives them, and writes grey frame pairs. Given one capture node and sensor, it captures that camera alone ([One camera with `v4l2_capture`](#one-camera-with-v4l2_capture)) |
| `jpeg_codec` | Encodes grey or RGB images as JPEG with libjpeg-turbo, colours depth previews, and decodes JPEG frames to grey, for `VisionCore.Jpeg` |
| `framing` | The `{:packet, 4}` framing the binaries share: a big-endian length prefix, little-endian scalars |

The Elixir side of the protocol is `VisionCore.Camera.LibCamera`, `VisionCore.Detection.Backend.Hailo`, `VisionCore.Detection.Backend.Qnn`, `VisionCore.Camera.V4L2Pair` and `VisionCore.Jpeg`; `qnn_segment`'s records are described in `qnn_segment/src/protocol.rs`. The stereo stages' native Port, `stereo_match`, is nx_stereo's: it builds it when it compiles.

The `device` feature of `camera_capture` and `hailo_detect` links the device libraries: libcamera from the system, `libhailort` from [`libraries/hailort`](../../libraries/hailort), whose header and library directories `../core/Makefile` passes as `HAILORT_INCLUDE_DIR` and `HAILORT_LINK_DIR`. Without it the crates build on any host, all but `qnn`, `qnn_detect` and `qnn_segment`, which is what the unit tests use:

```sh
cargo test
```

`../core/Makefile` runs the cross-build for each Nerves target, for the Cortex-A76 on `rpi5` and the Cortex-A78 on `arduino_ventuno_q`. It installs the target's Ports into `vision_core`'s `priv/`:

| Target | Ports |
|---|---|
| `rpi5` | `camera_capture`, `hailo_detect` and `jpeg_codec` |
| `okdo_c100` | `v4l2_capture` and `jpeg_codec` |
| `arduino_ventuno_q` | `v4l2_capture`, `jpeg_codec`, `qnn_detect` and `qnn_segment` |

`qnn` and the Ports on it are outside the workspace's default members. `qnn`'s bindings are generated with bindgen from the QNN headers of the QAIRT archive `mise run fetch-qairt` caches, which the Makefile extracts. Nothing derived from them is committed.

Their unit tests need those headers too: `QAIRT_INCLUDE_DIR=<qairt>/include/QNN cargo test -p qnn -p qnn_detect -p qnn_segment`. The `vision_core` tests build `jpeg_codec` for the host themselves. The workspace needs the `aarch64-unknown-linux-gnu` Rust target (`mise install`) and a host libclang for bindgen.

`jpeg_codec` and `v4l2_capture` link libjpeg-turbo's TurboJPEG library. On `rpi5` and `arduino_ventuno_q` the Makefile links the one the Nerves system ships, found with pkg-config. On `okdo_c100`, whose system ships none, and on the host, the `turbojpeg-sys` crate builds it from its bundled source and links it statically. That needs cmake.

The Arm builds use its NEON code. An x86-64 host build uses its SIMD code only when nasm is installed, and encodes about three times slower without it.

## `qnn`

The library the QNN Ports share:

- runs a context binary's first graph on the Hexagon NPU through QNN's HTP backend, under a power vote: a performance profile (`--performance <profile>`, `burst` by default) and the RPC polling (`--rpc-polling-us <us>`, 0 by default);
- times each execution;
- prints a DLC's graph names (`--graph-names <dlc>`);
- reads the Ports' command line and requests, and writes their replies (`qnn::port`);
- writes the Ports' statistics line.

An execution's stages are:

- the wall time around `graphExecute`;
- the times QNN's profile reports inside it:
  - `QNN execute`;
  - the remote procedure call as the CPU and as the HTP time it, `host RPC` and `HTP RPC`;
  - the graph on the HTP, `HTP`;
- reading the profile after it (`profile read`).

## One camera with `v4l2_capture`

Given one capture node and sensor (`--video`, `--sensor`), `v4l2_capture` captures that camera alone, such as the IMX477 on the VENTUNO Q in packed 12-bit Bayer. It writes one record per output per frame, tagged with the output's index (OUTPUT_FRAME). Each `--output` is one of:

- `cpu:<width>x<height>`: made by the software conversion with grey-world white balance, demosaiced bilinearly at the capture's size or 2×2 at half of it;
- `from:<index>:<width>x<height>`: averaged from an earlier output in blocks of a whole fraction of its size;
- `from:<index>:<width>x<height>:jpeg:<quality>`: encoded from an earlier output as a JPEG with libjpeg-turbo, at that output's size or a whole fraction of it. It writes one OUTPUT_JPEG record per frame, its chroma 4:2:0 below quality 90 as `jpeg_codec`'s;
- `from:<index>:<width>x<height>:h264:<bitrate_kbps>:<keyframe_interval>`: encoded from an earlier output as H.264 on the board's video encoder, at that output's size or a whole fraction of it, its width and height even, at a constant `bitrate_kbps` with a key frame every `keyframe_interval` frames. It writes one OUTPUT_H264 record per frame: the frame's NAL units in Annex B form after a key frame flag, the sequence and picture parameter sets before each key frame.

A JPEG or H.264 output is always sent, and no output is made from it.

Metadata records, before a frame's records, carry what the program set: the exposure and gain when auto exposure changes them, and, under the grey-world white balance, the red and blue gains applied to that frame when they change (`VisionCore.Camera.V4L2Capture.parse_record/1`).

The H.264 encoder is a V4L2 memory-to-memory device behind an encoder trait: on the VENTUNO Q, Qualcomm's Iris (`qcom-iris-encoder`), which needs the firmware `qcom/vpu/vpu30_p4_s6.mbn`. Without it, the program stops at start. The output's image is converted to NV12 in BT.601 limited range (luma 16 to 235), each chroma sample the mean of a 2×2 block, into the encoder's padded layout. For an output the size of a conversion output, the conversion makes it as each pair of rows is written; otherwise it is made after the averaging, on the same threads.

The conversion sits behind a processor trait, so another processor, such as an ISP, slots in beside it.

For the IMX477 the conversion follows libcamera's Raspberry Pi pipeline with Raspberry Pi's tuning:

- lens shading;
- the colour correction matrix of the colour temperature;
- a chroma denoise at the resolution of the 2×2 cells;
- the contrast curve.

Auto exposure measures the green after lens shading and white balance, through the curve, before the colour matrix and the denoise. The `ccm=false` and `denoise=false` settings leave the matrix and the denoise out. Other sensors take the plain `gamma`. `v4l2_capture/libcamera_tuning.py` writes a sensor's tuning module from libcamera's tuning file.

It converts each frame in bands of rows on `threads` threads, 1 to 8. The default is 3 with an output at the capture's size, and 1 otherwise. The 2×2 average of a conversion output is made as each pair of its rows is written. The other outputs made from others are averaged after it, on the same threads.

A writer thread writes each frame's outputs while the next one converts. An encoder thread encodes the frame's JPEGs, and another its H.264 outputs, while the writer writes its other outputs.

Its statistics line, every minute, gives the time per frame of:

- the conversion;
- the averaging after it (`us per scaling`, 0 when the conversion makes every average);
- the writes;
- the JPEG encodes;
- the conversion to NV12 after it (`us per NV12 conversion`, 0 when the conversion makes every NV12);
- the H.264 encodes, from the frame queued to the encoder to its stream dequeued;

and the H.264 bytes per second.
