---
title: Where depth is computed
description: How the vision unit runs its stereo stages, compiled from Nx for a GPU or in native Rust on CPU cores, and how each path uses the GPU, the processor and memory.
---

The [stereo stages](./stages.md) are written once and run one of two ways, depending on the board:

| | OKdo Nano C100 | Raspberry Pi 5 |
|---|---|---|
| Stages | Nx, compiled by `nx_iree` into Vulkan compute shaders | Native Rust, in the `stereo_match` Port |
| Runs on | the GPU: 128 Maxwell cores | the CPU: 4 Cortex-A76 cores |
| Composer | `defn_options: VisionCore.Stereo.NxSegment.c100_defn_options/1` | `compute: :native` |
| Detection | none | the Hailo-8, through `hailo_detect` |

Both give the same results: the native stages are tested against the Nx ones, image for image.

To see where each stage of a running unit is computed, select it on the dashboard: its panel is tagged with where it runs (CPU or GPU), what it is written in (Rust, Elixir or Elixir Nx) and, for Nx, what compiles it (Vulkan, LLVM, EXLA or the Nx evaluator). `GET /api/stages` returns the same as each stage's `compute` attribute.

## Nx: the stages as tensor programs

[Nx](https://github.com/elixir-nx/nx) is Elixir's library for numerical computing: a function written with `defn` works on whole tensors, and a compiler turns it into code for a CPU or a GPU. Each stage implements `VisionCore.Stereo.NxStage`, whose `step` is such a function. The image algorithms come from [`nx_stereo`](https://github.com/Spin42/nx_stereo):

| Module | What it provides |
|---|---|
| `NxStereo.sgm/3` | libSGM's semi-global matching: census, path aggregation, selection, consistency check |
| `NxStereo.Rectify` | Undistortion, rectification and shrinking in one sampling pass |
| `NxStereo.Depth` | Disparity to depth in millimetres and metres |

The Pipeline joins consecutive Nx stages into one `VisionCore.Stereo.NxSegment`, compiled once when the pipeline starts. A pair then goes to the device once, every stage of the segment runs there, and the outputs come back once. A value that changes while running, such as a calibration or a live setting like `p1`, is an input of the compiled function; a build setting such as `num_disparities` is compiled in.

The compiler comes from the `:defn_options` of the `:stereo` component:

| Compiler | Where | Used for |
|---|---|---|
| EXLA (XLA) | your workstation | development and the tests; the default when EXLA is loaded |
| [`nx_iree`](https://github.com/Spin42/nx_iree) with `vulkan-spirv` | compiled on your workstation, run on the C100's GPU | `c100_defn_options/1` |
| `nx_iree` with `llvm-cpu` | compiled on your workstation, run on the Pi 5's cores | `rpi5_defn_options/1`, for the Nx stages that have no native implementation |

`nx_iree` compiles the segment with [IREE](https://iree.dev) into a module that the IREE runtime on the board loads and runs. A board has neither EXLA nor the IREE compiler, so the modules are compiled on your workstation into a cache directory in your vehicle's `priv/`. Run this in your vehicle's project, on the host, where `vision_firmware` brings EXLA:

```sh
cd vehicles/<vehicle>
mix vision_core.nx_cache --composer <Vehicle>.Vision.Composer --out priv/nx_iree_cache
```

It compiles what the composer's stereo pipeline compiles when it starts. The cache keys each module on the stages, their build settings and the working size, so rebuild it after changing any of them; a unit whose cache lacks a module fails to start its stereo pipeline. A new calibration needs no rebuild. List the directory in `required_files/0` so a build without it fails.

## On the C100's GPU

The Jetson Nano module of the C100 has 4 Cortex-A57 cores and a 128-core Maxwell GPU, about 236 GFLOPS in 32-bit floats, sharing 4 GB of LPDDR4 memory.

```text
 v4l2_capture ──grey pair──► BEAM ──upload──► GPU: every stage as compute shaders ──download──► BEAM
```

1. `v4l2_capture` writes each grey pair into the BEAM through its pipe.
2. The segment's inputs are copied into GPU buffers. CPU and GPU share the same memory chips, so this is a copy within memory, not across a bus.
3. Every stage runs as Vulkan compute shaders, with libSGM's algorithm for the matching. The temporal filter's previous disparity stays on the GPU from one pair to the next.
4. The outputs are copied back once, and the stages after the segment run on the BEAM.

While one pair's outputs are collected, the next pair's GPU work already runs. The CPU's part is capture, the copies and publishing; the GPU does the arithmetic. The dashboard's Stereo load is the share of each second the segment takes, waits for the GPU included.

## On the Raspberry Pi 5's CPU

The Pi 5 has 4 Cortex-A76 cores at 2.4 GHz, a VideoCore VII GPU and LPDDR4X memory on a 32-bit bus. The stages run on the CPU cores, in native code:

- **Not the GPU.** The Raspberry Pi 5 system image has no Vulkan driver, and the VideoCore VII, about 77 GFLOPS, is slower than the four A76 cores together, about 150.
- **Not Nx on the CPU.** For a CPU target, `NxStereo.sgm/3` runs its path aggregation as a loop of small tensor updates, which compiled code runs very slowly. At 480 × 360, the compiled matching took about 60 s a pair on the Pi 5, against 117 ms for the first native version.

### The `stereo_match` Port

With `compute: :native` on the `:stereo` component, every default stage runs in `stereo_match`, a Rust program the BEAM drives as a Port:

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
| `VisionCore.Stereo.NativeSegment` | The counterpart of `NxSegment`: a run of consecutive native stages, configured once in the Port and run on each pair. |
| `VisionCore.Stereo.Matcher` | The process that owns the Port, queues requests and matches each reply to its request. It reopens the Port if it exits; a request with no reply within 5 s closes it. |

The Port keeps each segment's state between pairs: the rectification sampling maps, the matching buffers and the temporal filter's previous disparity. A segment is configured on its first pair, and again after a calibration reload or a restart of the Port, which loses every segment's state. The protocol has three requests, configure, run and release, each one length-prefixed record over the pipes; `vision/rust/stereo_match/src/protocol.rs` defines it.

The stages keep their names, settings and outputs, so the publishers, the dashboard and detection work the same. A stage can override the component's choice: `Disparity`'s `matcher: :native` matches natively in a pipeline otherwise compiled with Nx, and `matcher: :nx` compiles the matching in a native one. A stage of your own runs between the native segments around it, which hand it their outputs: an Nx stage without a native implementation becomes a compiled segment of its own, so the component also needs `:defn_options`, `rpi5_defn_options/1` on the Pi 5, and a module cache; a stage that is not written in Nx runs on the BEAM.

### Threads

```text
 reader thread    reads and parses the next pair from stdin
 compute pool     one thread per core: the stages of the current pair
 writer thread    writes the previous pair's outputs to stdout
```

The Pipeline keeps two pairs at the Port, so reading, computing and writing overlap ([How a pair flows](./data_flow.md#two-pairs-in-flight)). The compute threads are started once and kept, blocked between pairs. Inside a stage, work is handed out in small items, usually image rows, as they become ready, rather than split into fixed shares; a thread waiting for a row another thread is finishing spins briefly, then yields its core, then sleeps. On a board where the BEAM, the camera Ports and `jpeg_codec` share the same four cores, a thread that loses its core then delays only the row it holds, not the whole stage. `config :vision_core, :stereo_match_threads` sets the pool size, one thread per core by default.

### Memory and the processor

The matching is the cost. For every pixel it keeps one cost per candidate disparity, and with `paths: 8` those volumes do not fit in any cache:

| Buffer | Size | At 480 × 270, 64 disparities |
|---|---|---|
| One cost volume, 1 byte per pixel per disparity | W × H × D | 8.3 MB |
| `paths: 8`: costs, horizontal sums, and 16-bit totals | 4 × W × H × D | 33 MB |
| `paths: 3`: costs and horizontal sums for a ring of rows | 1 MiB | 1 MiB |

Each A76 core has 512 KB of L2 cache, and the four share 2 MB of L3. With 8 paths, the matcher sweeps the image down and then up, so its volumes go through main memory several times per pair. With 3 paths it makes one pass down the image: the costs of the rows just computed sit in a ring that stays in cache, and each row is freed once the vertical path has gone through it. That is the main reason 3 paths are much faster on the Pi than the path count alone suggests.

The arithmetic is shaped for the A76's 128-bit NEON registers:

- **Costs fit in bytes.** A cost is at most `p2 + 48`, below 128, so a register holds 16 of them and two paths add without overflow.
- **Census in bit planes.** The 48-bit signatures are six byte planes, so a pixel's costs over all its disparities are byte popcounts over contiguous memory.
- **Winner search.** The search for the best disparity is written with NEON intrinsics.
- **Tuned build.** `stereo_match` is built with `-C target-cpu=cortex-a76`.

Memory bandwidth is still what limits the Pi. The cameras' image signal processor writes every frame to the same memory, so with the cameras running a plain memory copy goes from about 3.2 GB/s to about 1.1 to 1.5 GB/s. Together with the other processes on the cores, this makes the same stereo work take about three times longer while the unit runs than on an idle board.

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

The core runs its Rust programs as Ports: separate processes speaking length-prefixed binary records over stdin and stdout, not NIFs loaded into the BEAM, so a crash in one cannot take the BEAM down.

| Port | Board | What it does |
|---|---|---|
| `camera_capture` | Pi 5 | One libcamera camera: the image signal processor's output as grey frames (`format: :grey`) or JPEG; takes camera controls on stdin. |
| `v4l2_capture` | C100 | Both CSI cameras over V4L2: locks the right sensor's frame starts to the left one's and writes grey pairs. |
| `stereo_match` | Pi 5, workstation | The native stereo stages. |
| `jpeg_codec` | both | Encodes grey images and coloured depth previews as JPEG, and decodes JPEG frames to grey. |
| `hailo_detect` | Pi 5 | Runs the detection model on the Hailo-8 through HailoRT and returns boxes. |

Compiling `vision_core` for a vision target cross-builds that target's Ports through `vision/core/Makefile`: `camera_capture`, `hailo_detect`, `jpeg_codec` and `stereo_match` for `rpi5`, `v4l2_capture` and `jpeg_codec` for `okdo_c100`. On a workstation, `mix compile` builds `jpeg_codec` and `stereo_match` for the host. The build host needs the `aarch64-unknown-linux-gnu` Rust target, which `mise install` provides, and libclang for bindgen. Each crate is described in [`vision/rust/README.md`](../../vision/rust/README.md).

## Grey frames on the Pi 5

Give both cameras `format: :grey` in the `:stereo` component's `:left` and `:right` options. `camera_capture` then sends the luma plane the image signal processor already produced, one byte per pixel. Without it, each frame is encoded to JPEG in `camera_capture` and decoded again on the BEAM's side, two pieces of CPU work per frame for nothing. Only the frames that actually leave the unit are encoded: raw images at most `:raw_image_max_hz` a second, and the dashboard's previews while it is open.

## See also

- [Stereo stages](./stages.md)
- [Vision performance](./performance.md)
- [`vision/core/README.md`](../../vision/core/README.md): how the tests compare the native stages with Nx.
