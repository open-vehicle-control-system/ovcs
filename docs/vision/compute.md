---
title: Where depth is computed
description: How the vision unit runs its stereo stages, compiled from Nx for a GPU or in native Rust on CPU cores, and how each path uses the GPU, the processor and memory.
---

The [stereo stages](./stages.md) are written once and run one of two ways, depending on the board:

| | OKdo Nano C100 | Arduino VENTUNO Q | Raspberry Pi 5 |
|---|---|---|---|
| Stages | Nx, compiled by `nx_iree` into Vulkan compute shaders | Nx, compiled by `nx_iree` into Vulkan compute shaders | Native Rust, in the `stereo_match` Port |
| Runs on | the GPU: 128 Maxwell cores | the GPU: an Adreno 623 | the CPU: 4 Cortex-A76 cores |
| Composer | `defn_options: VisionCore.Stereo.NxSegment.c100_defn_options/1` | `defn_options: VisionCore.Stereo.NxSegment.ventuno_q_defn_options/1` | `compute: :native` |
| Detection | none | the Hexagon NPU, through `qnn_detect` | the Hailo-8, through `hailo_detect` |
| Road segmentation | none | the Hexagon NPU, through `qnn_segment` | none |

Both give the same results: the native stages are tested against the Nx ones, image for image.

To see where each stage of a running unit is computed, select it on the dashboard. It gives:

- where the stage runs: CPU or GPU;
- what it is written in: Rust, Elixir or Elixir Nx;
- for Nx, what compiles it: Vulkan, LLVM, EXLA or the Nx evaluator.

`GET /api/stages` returns the same as each stage's `compute` attribute.

## Nx: the stages as tensor programs

[Nx](https://github.com/elixir-nx/nx) is Elixir's library for numerical computing. A function written with `defn` works on whole tensors, and a compiler turns it into code for a CPU or a GPU. Each stage implements `VisionCore.Stereo.NxStage`, whose `step` is such a function. The image algorithms come from [`nx_stereo`](https://github.com/Spin42/nx_stereo):

| Module | What it provides |
|---|---|
| `NxStereo.sgm/3` | libSGM's semi-global matching: census, path aggregation, selection, consistency check |
| `NxStereo.Rectify` | Undistortion, rectification and shrinking in one sampling pass |
| `NxStereo.Depth` | Disparity to depth in millimetres and metres |

The Pipeline joins consecutive Nx stages into one `VisionCore.Stereo.NxSegment`, compiled once when the pipeline starts. A pair then goes to the device once, every stage of the segment runs there, and the outputs come back once. A value that changes while running, such as a calibration or a live setting like `p1`, is an input of the compiled function. A build setting such as `num_disparities` is compiled in.

The compiler comes from the `:defn_options` of the `:stereo` component. They go to `VisionCore.Stereo.NxSegment`, the second of the component's default backends, after `VisionCore.Stereo.NativeSegment`. A component can list its own `:backends` instead, each `{module, opts}`, with `defn_options:` among NxSegment's options:

| Compiler | Where | Used for |
|---|---|---|
| EXLA (XLA) | your workstation | development and the tests; the default when EXLA is loaded |
| [`nx_iree`](https://github.com/Spin42/nx_iree) with `vulkan-spirv` | compiled on your workstation, run on the C100's GPU | `c100_defn_options/1` |
| `nx_iree` with `vulkan-spirv` | compiled on your workstation, run on the VENTUNO Q's GPU | `ventuno_q_defn_options/1` |
| `nx_iree` with `llvm-cpu` | compiled on your workstation, run on the Pi 5's cores | `rpi5_defn_options/1`, for the Nx stages that have no native implementation |

`nx_iree` compiles the segment with [IREE](https://iree.dev) into a module that the IREE runtime on the board loads and runs.

On a Vulkan GPU, the stages run hand-written compute shaders, not code IREE generates. Each stage's step is an `Nx.block`. Its Vulkan implementation is a shader; its default, run everywhere else, is the stage's Nx code. IREE generates only the few operations between the blocks.

Every stage's computation and shader ships with [`nx_stereo`](https://github.com/Spin42/nx_stereo):

- the matching's, derived from libSGM;
- those of rectification, the filters, depth, the point cloud, and the sharpness, row alignment and quality measures.

Each stage in `vision_core` adds its settings, its dashboard text and what it publishes.

The shaders read and write 32-bit words only. They therefore also run on GPUs without 8-bit storage, such as the Adreno of the Arduino VENTUNO Q, where code IREE generates for 8-bit values gives wrong results. For such a GPU, the defn options carry `byte_storage: false`, as `ventuno_q_defn_options/1` does. The segment's 8-bit frames and images then cross to and from the device as 32-bit words, four pixels each (`NxStereo.Packing`), so no 8-bit buffer reaches the GPU.

The shaders give the Nx code's results, except where floating-point rounding differs:

- a rectified pixel can be 1 grey level off where a sample falls on a rounding half, and the subpixel disparity follows;
- depths and points can differ in their last bits, as a GPU's division is not correctly rounded.

In `nx_stereo`, `mix test --include vulkan` checks each shader against its Nx code on your workstation's GPU, and `mix run bench/pipeline.exs` times each stage there. In `vision_core`, `mix test --include vulkan` checks the stages and a whole pipeline against EXLA. The matching shaders depend on the GPU's subgroup operations, so a new GPU needs them checked against the Nx version.

A board has neither EXLA nor the IREE compiler, so the modules are compiled on your workstation into a cache directory in your vehicle's `priv/`. Run this in your vehicle's project, on the host, where `vision_firmware` brings EXLA:

```sh
cd vehicles/<vehicle>
mix vision_core.nx_cache --composer <Vehicle>.Vision.Composer --out priv/nx_iree_cache
```

It compiles what the composer's stereo pipeline compiles when it starts. The cache keys each module on the stages, their build settings and the working size, so rebuild it after changing any of them. A unit whose cache lacks a module fails to start its stereo pipeline. A new calibration needs no rebuild. List the directory in `required_files/0` so a build without it fails.

## On the C100's GPU

The Jetson Nano module of the C100 has 4 Cortex-A57 cores and a 128-core Maxwell GPU, about 236 GFLOPS in 32-bit floats. They share 4 GB of LPDDR4 memory.

```text
 v4l2_capture ──grey pair──► BEAM ──upload──► GPU: every stage as compute shaders ──download──► BEAM
```

1. `v4l2_capture` writes each grey pair into the BEAM through its pipe.
2. The segment's inputs are copied into GPU buffers. CPU and GPU share the same memory chips, so this is a copy within memory, not across a bus.
3. Every stage runs as Vulkan compute shaders, with libSGM's algorithm for the matching. The temporal filter's previous disparity stays on the GPU from one pair to the next.
4. The outputs are copied back once, and the stages after the segment run on the BEAM.

While one pair's outputs are collected, the next pair's GPU work already runs. The CPU's part is capture, the copies and publishing; the GPU does the arithmetic. The dashboard's Stereo load is the share of each second the segment takes, waits for the GPU included.

## On the VENTUNO Q's GPU

The QCS8300 of the Arduino VENTUNO Q has 4 Cortex-A78C and 4 Cortex-A55 cores and an Adreno 623 GPU. They share 16 GB of memory. Its system runs Vulkan through Mesa's Turnip driver.

A pair goes through the same steps as on the C100. It is packed into 32-bit words on its way to the GPU and unpacked on its way back, since the Adreno has no 8-bit storage. Two settings of the vision firmware serve the GPU, on this target only:

- **Vulkan pool slabs.** The firmware sets `IREE_HAL_VULKAN_SLAB_SIZE` to 512 MiB through erlinit: larger slabs keep a stereo segment's transient buffers pooled.
- **GPU clock.** `OvcsVehicle.CpuGovernor` pins the GPU at its maximum frequency, 877 MHz. It waits for the GPU's devfreq device, which appears seconds after boot.

## On the Raspberry Pi 5's CPU

The Pi 5 has 4 Cortex-A76 cores at 2.4 GHz, a VideoCore VII GPU and LPDDR4X memory on a 32-bit bus. The stages run on the CPU cores, in native code:

- **Not the GPU.** The Raspberry Pi 5 system image has no Vulkan driver, and the VideoCore VII, about 77 GFLOPS, is slower than the four A76 cores together, about 150.
- **Not Nx on the CPU.** For a CPU target, `NxStereo.sgm/3` runs its path aggregation as a loop of small tensor updates, which compiled code runs very slowly. At 480 × 360, the compiled matching took about 60 s a pair on the Pi 5, against 117 ms for the first native version.

### The `stereo_match` Port

With `compute: :native` on the `:stereo` component, every default stage runs in `stereo_match`. It is the Rust program that [`nx_stereo`](https://github.com/Spin42/nx_stereo) computes its stages with on a CPU. The BEAM drives it as a Port:

```elixir
{:stereo,
 [
   compute: :native,
   stages: Pipeline.default_stages(disparity: [num_disparities: 64, paths: 3]),
   # driver, sizes, calibration and cameras
 ]}
```

| Elixir side | Role |
|---|---|
| `VisionCore.Stereo.NativeSegment` | The counterpart of `NxSegment`: a run of consecutive native stages, configured once in the Port and run on each pair. It runs nx_stereo's `NxStereo.NativeSegment` on the pipeline's pairs, as `NxSegment` runs `NxStereo.NxSegment`. |
| `VisionCore.Stereo.Matcher` | The `NxStereo.Matcher` process that owns the Port, queues requests and matches each reply to its request. It reopens the Port if it exits; a request with no reply within 5 s closes it. |

The Port keeps each segment's state between pairs: the rectification sampling maps, the matching buffers and the temporal filter's previous disparity. A segment is configured on its first pair. It is configured again after a calibration reload, or after a restart of the Port, which loses every segment's state.

The configuration holds each stage's kind, its build settings and the constants its Nx step shares with the Port, such as the point cloud's depth range. Each is thus written once, in the stage.

The Port refuses a configuration it cannot run, such as a kind it has no implementation of or a setting the stage does not take. The pipeline then stops at that first pair, and the log says why. Frames smaller than the working size are refused earlier, when the pipeline starts, by Rectification.

The protocol has three requests: configure, run and release. Each is one length-prefixed record over the pipes. nx_stereo's `native/stereo_match/src/protocol.rs` defines it.

The stages keep their names, settings and outputs, so the exporters, the dashboard and detection work the same.

A stage can override the component's choice with `compute: :native` or `compute: :nx` among its options:

- `Pipeline.default_stages(disparity: [compute: :native])` matches natively in a pipeline otherwise compiled with Nx;
- `compute: :nx` compiles a stage in a native one.

`Disparity`'s `matcher:` option does the same for the matching, and must agree with a `compute:` given beside it. A stage asked to compute natively that no backend computes natively is refused at start.

Under `compute: :native`, a stage computes natively when it declares the kind of its native implementation with `native_kind/0`. Every default stage does. For a stage of your own:

- **It wraps a default stage.** It declares that stage's kind. For TemporalFilter, PointCloud, RowAlignment and SpeckleFilter it declares its `native_constants/0` too, or the pipeline stops at its first pair. It cannot add a numeric build setting of its own, which the Port would refuse.
- **It has no native kind.** It runs between the native segments around it, which hand it their outputs. An Nx stage becomes a compiled segment of its own, so the component also needs `:defn_options`, `rpi5_defn_options/1` on the Pi 5, and a module cache. Without a compiler, the pipeline refuses to start rather than run that stage on Nx's evaluator. A stage that is not written in Nx runs on the BEAM.

At start, the Pipeline logs each run of stages with where it computes, for example `rectification+sharpness (cpu, nx, llvm_cpu) → disparity (cpu, rust)`.

### Threads

```text
 reader thread    reads and parses the next pair from stdin
 compute pool     one thread per core: the stages of the current pair
 writer thread    writes the previous pair's outputs to stdout
```

The Pipeline keeps two pairs at the Port, so reading, computing and writing overlap ([How a pair flows](./data_flow.md#two-pairs-in-flight)). The compute threads are started once and kept, blocked between pairs.

Inside a stage, work is handed out in small items, usually image rows, as they become ready, not split into fixed shares. A thread waiting for a row another thread is finishing spins briefly, then yields its core, then sleeps. On a board where the BEAM, the camera Ports and `jpeg_codec` share the same four cores, a thread that loses its core then delays only the row it holds, not the whole stage.

`config :vision_core, :stereo_match_threads` sets the pool size, one thread per core by default.

### Memory and the processor

The matching is the cost. For every pixel it keeps one cost per candidate disparity, and with `paths: 8` those volumes do not fit in any cache:

| Buffer | Size | At 480 × 270, 64 disparities |
|---|---|---|
| One cost volume, 1 byte per pixel per disparity | W × H × D | 8.3 MB |
| `paths: 8`: costs, horizontal sums, and 16-bit totals | 4 × W × H × D | 33 MB |
| `paths: 3`: costs and horizontal sums for a ring of rows | 1 MiB | 1 MiB |

Each A76 core has 512 KB of L2 cache, and the four share 2 MB of L3. With 8 paths, the matcher sweeps the image down and then up, so its volumes go through main memory several times per pair. With 3 paths it makes one pass down the image. The costs of the rows just computed sit in a ring that stays in cache, and each row is freed once the vertical path has gone through it. That is the main reason 3 paths are much faster on the Pi than the path count alone suggests.

The arithmetic is shaped for the A76's 128-bit NEON registers:

- **Costs fit in bytes.** A cost is at most `p2 + 48`, below 128, so a register holds 16 of them and two paths add without overflow.
- **Census in bit planes.** The 48-bit signatures are six byte planes, so a pixel's costs over all its disparities are byte popcounts over contiguous memory.
- **Winner search.** The search for the best disparity is written with NEON intrinsics.
- **Tuned build.** `stereo_match` is built with `-C target-cpu=cortex-a76`.

Memory bandwidth is still what limits the Pi. The cameras' image signal processor writes every frame to the same memory. With the cameras running, a plain memory copy goes from about 3.2 GB/s to about 1.1 to 1.5 GB/s. Together with the other processes on the cores, this makes the same stereo work take about three times longer while the unit runs than on an idle board.

### What crosses the pipes

At 480 × 270, each pair moves about 1.4 MB through the Port's pipes. Replies are written straight from the computed images, without first copying them into one message.

| Direction | Content | Size |
|---|---|---|
| To the Port | left and right grey frames | 2 × 130 KB |
| From the Port | rectified left and right images | 2 × 130 KB |
| From the Port | disparity, 32-bit float | 518 KB |
| From the Port | depth, 16-bit millimetres | 259 KB |
| From the Port | point cloud at decimation 4 | about 100 KB |

The depth in metres, which PointCloud uses, never leaves the Port. The Port enlarges its pipes to 4 MiB where the system allows it, so a whole pair goes through without the Port waiting on the BEAM.

## Rust Ports

The core runs its Rust programs as Ports: separate processes speaking length-prefixed binary records over stdin and stdout. They are not NIFs loaded into the BEAM, so a crash in one cannot take the BEAM down.

| Port | Board | What it does |
|---|---|---|
| `camera_capture` | Pi 5 | One libcamera camera: the image signal processor's output as grey frames (`format: :grey`) or JPEG; takes camera controls on stdin. |
| `v4l2_capture` | C100, VENTUNO Q | Both CSI cameras over V4L2: locks the right sensor's frame starts to the left one's and writes grey pairs. A camera of its own in colour, its outputs converted, averaged or encoded as JPEG with libjpeg-turbo. |
| `stereo_match` | Pi 5, workstation | The native stereo stages, built by nx_stereo. |
| `jpeg_codec` | every board | Encodes grey and colour images and coloured depth previews as JPEG with libjpeg-turbo, and decodes JPEG frames to grey. The previews and the exporters encode on a pool of them, the configuration's `jpeg: [ports: n]`, each camera frame once for all of them. |
| `hailo_detect` | Pi 5 | Runs the detection model on the Hailo-8 through HailoRT and returns boxes. |
| `qnn_detect` | VENTUNO Q | Runs the detection model's context binary on the Hexagon NPU through QNN and returns boxes. |
| `qnn_segment` | VENTUNO Q | Runs the road segmentation model's context binary on the Hexagon NPU through QNN over a band of a colour frame and returns each output cell's class. |

Compiling `vision_core` for a vision target cross-builds that target's Ports through `vision/core/Makefile`:

| Target | Ports |
|---|---|
| `rpi5` | `camera_capture`, `hailo_detect` and `jpeg_codec` |
| `okdo_c100` | `v4l2_capture` and `jpeg_codec` |
| `arduino_ventuno_q` | `v4l2_capture`, `jpeg_codec`, `qnn_detect` and `qnn_segment` |

`qnn_detect` and `qnn_segment` share the `qnn` crate's QNN bindings, generated from the QAIRT archive `mise run fetch-qairt` caches.

On a workstation, `mix compile` builds `jpeg_codec` for the host. nx_stereo builds `stereo_match` itself, for the workstation or the target, whenever cargo is installed; `NX_STEREO_NATIVE=false` skips it.

The build host needs the `aarch64-unknown-linux-gnu` Rust target, which `mise install` provides, libclang for bindgen, and cmake, which builds libjpeg-turbo for `jpeg_codec` and `v4l2_capture` on the workstation and on `okdo_c100`, whose system does not ship it; on an x86-64 workstation, nasm gives that build its SIMD code. [`vision/rust/README.md`](../../vision/rust/README.md) describes each crate.

## Grey frames on the Pi 5

Give both cameras `format: :grey` in the `:stereo` component's `:left` and `:right` options. `camera_capture` then sends the luma plane the image signal processor already produced, one byte per pixel. Without it, each frame is encoded to JPEG in `camera_capture` and decoded again on the BEAM's side, two needless pieces of CPU work per frame.

Only the frames that leave the unit are encoded:

- raw images, at most `:raw_image_max_hz` a second, among the ROS 2 exporter's `stereo:` options;
- the dashboard's previews, while it is open.

## See also

- [Stereo stages](./stages.md)
- [Vision performance](./performance.md)
- [`vision/core/README.md`](../../vision/core/README.md): how the tests compare the native stages with Nx.
