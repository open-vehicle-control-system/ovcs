---
title: Stereo stages
description: What each stage of the vision unit's stereo pipeline does, what it reads and fills, its settings, and what it costs.
---

The stereo pipeline turns a pair of camera frames into a disparity, a depth image and a point cloud, through a list of stages. `VisionCore.Stereo.Pipeline.default_stages/1` returns the default list, which your vehicle's composer can change stage by stage. This guide describes each one. How a pair reaches the stages is in [How a pair flows](./data_flow.md); where they run, in [Where depth is computed](./compute.md).

## Why stereo gives depth

Two cameras side by side see a point at slightly different horizontal positions. That shift, the **disparity** `d` in pixels, shrinks with distance:

```text
Z = f × B / d
```

`Z` is the depth in metres, `f` the focal length in pixels and `B` the baseline, the distance between the two cameras; [Stereo vision basics](./basics.md) explains them with diagrams. Finding `d` for every pixel is the expensive part. It becomes a search along one image row once both images are **rectified**: undistorted and rotated so that a point lies on the same row in both.

Two consequences shape the settings below:

- **Nearest distance.** The matcher searches `num_disparities` positions, so the nearest point it can measure is `f × B / num_disparities`. More disparities measure nearer, and cost proportionally more.
- **Precision.** One pixel of disparity is worth more metres far away than near: the depth error grows with the square of the distance. A larger image (larger `f`) or a wider baseline measures far points better.

## The default stages

They run in this order. Each stage declares what it reads from the pair and what it fills; the Pipeline checks at start that every field a stage reads is filled by a stage before it.

| # | Stage | Reads | Fills | Role |
|---|---|---|---|---|
| 1 | Rectification | camera frames | `left`, `right` | Undistorted, rectified grey images at the working size |
| 2 | Sharpness | `left`, `right` | `sharpness` | Compares the cameras' focus |
| 3 | Disparity | `left`, `right` | `disparity`, `disparity_range` | Semi-global matching |
| 4 | MedianFilter | `disparity` | `disparity` | Removes isolated wrong pixels |
| 5 | SpeckleFilter | `disparity` | `disparity` | Removes small unsupported islands |
| 6 | RowAlignment | `left`, `right`, `disparity` | `alignment` | Checks the calibration still fits |
| 7 | TemporalFilter | `disparity` | `disparity` | Smooths over time |
| 8 | Depth | `disparity` | `depth`, `disparity_bytes` | Disparity to millimetres |
| 9 | PointCloud | depth in metres | `cloud` | Decimated 3D points |
| 10 | Quality | `disparity` | metrics | Statistics for the log line |

Below, **the device** is wherever the stages run: the GPU on the C100, the `stereo_match` Port on the Pi 5. Values that stay on the device are not sent back to the BEAM.

A setting is either **live** or **build**:

- **Live** settings change while the unit runs, from the dashboard or as ROS 2 parameters under `<prefix>.<stage>.<setting>`, where the prefix is the component's `:topic_prefix`, `stereo` by default (`stereo.disparity.p1`). They apply from the next pair; with native stages, from the second pair after the change, since one pair is already in the Port ([Two pairs in flight](./data_flow.md#two-pairs-in-flight)).
- **Build** settings are fixed when the pipeline starts, because they decide the shape of what it computes. You set them in your composer, for example `Pipeline.default_stages(disparity: [num_disparities: 128])`. The dashboard shows them locked.

The costs below were measured on a Raspberry Pi 5 matching 480 × 270 with 64 disparities over 3 paths, while both cameras captured at 30 frames a second: the median time of each stage in the `stereo_match` Port. [Vision performance](./performance.md) has the full measurements.

### 1. Rectification

Undistorts and rectifies both camera frames with each camera's calibration, so a point lies on the same row in both, and shrinks frames larger than the working size in the same pass. Each output pixel is one bilinear sample of the camera frame, read through a sampling map computed once per calibration.

| Setting | Default | Kind | Meaning |
|---|---|---|---|
| `right_row_offset` | 0.0 | live | Rows the right image is moved by, −8 to 8: a correction for cameras that have shifted since the calibration. |

`VisionCore.Stereo.AlignmentCorrection` sets `right_row_offset` for you, on by default (`:align_correction` on the `:stereo` component): when RowAlignment keeps reading an offset beyond a tenth of a row, it moves the right image, up to six rows. It corrects rows only; a camera that moved sideways needs a new calibration. Its switch, `auto_row_offset`, sits next to `right_row_offset` in the Rectification settings: switch it off to keep the offset it reached, or one you set by hand.

The calibrations are inputs, not compiled in, so a new calibration needs no rebuild. Cost on the Pi 5: about 6 ms.

### 2. Sharpness

Measures how sharp each rectified image is: the mean squared difference between horizontal neighbours, divided by the square of the mean grey so that a brightness difference between the cameras does not count. The absolute value depends on the scene; the ratio between the two cameras tells you whether one is out of focus. The dashboard shows it next to the synchronisation. Cost: under 1 ms.

### 3. Disparity

Matches the rectified pair with **semi-global matching** (SGM), the algorithm of [libSGM](https://github.com/fixstars/libSGM), through `NxStereo.sgm/3`:

1. **Census transform.** Each pixel becomes a 48-bit signature of its 9 × 7 neighbourhood: one bit for each neighbour off the centre's row and column, set when the neighbour is more than one grey level darker than the centre. Signatures compare brightness within one image, so they survive brightness differences between the cameras.
2. **Matching cost.** For each pixel and each candidate disparity, the cost is the number of differing bits between the left signature and the right one at that shift: a Hamming distance, 0 to 48.
3. **Aggregation.** A pixel's cost alone is noisy. SGM adds, along several straight paths across the image, the best cost of the previous pixel on the path, plus a penalty `p1` when the disparity changes by one and `p2` when it jumps further. This makes neighbouring pixels agree except at real edges.
4. **Selection.** Each pixel takes the disparity with the lowest total, refined to a fraction of a pixel from its two neighbours' costs. It is dropped when the second-best total is not at least `uniqueness` times higher, which rejects ambiguous matches on repetitive or textureless surfaces.
5. **Consistency.** The match is repeated from the right image's point of view, and a pixel whose two matches disagree is dropped: typically a pixel the right camera cannot see. A 3 × 3 median ends the stage.

Unmatched pixels carry a disparity of −1.

| Setting | Default | Kind | Meaning |
|---|---|---|---|
| `num_disparities` | 64 | build | Positions searched, 64 or 128. Sets the nearest measurable distance. |
| `paths` | 8 | build | Aggregation paths, 8 or 3. 3 paths (left to right, right to left, top to bottom) take much less time than 8, on a GPU about a quarter, and leave more pixels unmatched on dark or textureless surfaces. |
| `p1` | 8 | live | Penalty for a disparity change of one pixel between neighbours, 0 to 78. |
| `p2` | 64 | live | Penalty for a larger change, 1 to 79, above `p1`. Higher makes surfaces smoother and edges blurrier. |
| `uniqueness` | 1.0526 | live | How much better than the second-best match the best must be, 1 to 3. Higher drops more ambiguous pixels. |

`:matcher` (`:native` or `:nx`), given in the composer, makes this stage run natively or compiled whatever the rest of the pipeline does. Cost on the Pi 5: about 30 ms, two thirds of the pipeline.

### 4. MedianFilter

Replaces each disparity with the median of its neighbourhood, which removes isolated wrong pixels without blurring edges.

| Setting | Default | Kind | Meaning |
|---|---|---|---|
| `kernel_size` | 5 | build | Neighbourhood width, 3 or 5. |

Cost: about 2 ms at 3.

### 5. SpeckleFilter

Drops speckles: small islands of disparity that agree with nothing around them, typically false matches on reflections or fine repetitive structure. A matched pixel is kept when at least `min_support` of the 48 other pixels in its 7 × 7 neighbourhood matched within `max_diff` pixels of it. Islands smaller than about 4 × 4 lose their support; surfaces keep theirs up to their corners. It plays the part of OpenCV's `filterSpeckles`, which labels connected regions instead, a poor fit for a GPU.

| Setting | Default | Kind | Meaning |
|---|---|---|---|
| `min_support` | 12 | live | Neighbours that must agree, 0 to 48. |
| `max_diff` | 1.0 | live | How close, in pixels, a neighbour must be. |

Cost: about 3 ms.

### 6. RowAlignment

Measures how well the rectified images line up. A calibration that no longer fits the cameras, because a camera or a lens moved, breaks that first. Each matched pixel is compared with the right image at its disparity on the rows 2 above to 2 below its own, in four vertical bands; the row with the lowest difference is the offset there. The dashboard shows it as Row alignment: within half a row is good, a larger offset means recalibrate, and offsets that change from band to band mean a rotation. Cost: under 1 ms.

### 7. TemporalFilter

Smooths the disparity over time. Where a pixel matched in this pair and the previous one, within `delta` pixels of each other, it moves `alpha` of the way from the previous value to the new one; elsewhere it takes the new value, so motion and new edges show at once. A pixel that loses its match keeps its last disparity for up to `hold` pairs. On a still scene this removes most of the flicker of the subpixel estimates and the holes that come and go.

| Setting | Default | Kind | Meaning |
|---|---|---|---|
| `alpha` | 0.4 | live | Weight of the new value; 1.0 turns smoothing off. |
| `delta` | 2.0 | live | Largest change, in pixels, that is smoothed. |
| `hold` | 2 | live | Pairs a lost match is held; 0 turns holding off. |

This stage carries the previous disparity from one pair to the next, on the device that runs it. Cost: about 2 ms.

### 8. Depth

Turns the disparity into depth with `Z = f × B / d`, taking `f` and `B` from the calibration. It fills the 16-bit millimetre depth the depth topic and detection use, and the 32-bit float disparity the disparity topic carries. It also computes the depth in metres for the stages after it in the same segment, PointCloud among them; that image stays on the device. Unmatched pixels have no depth (0). Cost: about 2 ms.

### 9. PointCloud

Unprojects one depth pixel every `decimation` in each direction into an `x, y, z` point in the left camera's optical frame. Points nearer than 5 cm or farther than 20 m, and unmatched pixels, are NaN, as ROS organized clouds mark them.

| Setting | Default | Kind | Meaning |
|---|---|---|---|
| `decimation` | 4 | build | Keeps one pixel in `decimation` × `decimation`, 1 to 16. |

Cost: under 1 ms.

### 10. Quality

Measures the disparity on every pair: the share of matched pixels, the mean and spread of their disparity, and the jitter, the mean change of a pixel's disparity from one pair to the next (the matcher's noise on a still scene). Its sums are taken on the device; only five numbers come back. The depth caption on the dashboard shows the matched share. Cost: about 1 ms.

## Your own stages

A stage is a module implementing `VisionCore.Stereo.Stage`, or `VisionCore.Stereo.NxStage` for a stage written in Nx; its documentation lists the callbacks. Put it in your composer's `:stages` list. An Nx stage compiles into the segment around it. With `compute: :native`, an Nx stage without a native implementation becomes a compiled segment of its own between the native ones, so the component also needs `:defn_options` and a module cache ([Where depth is computed](./compute.md#nx-the-stages-as-tensor-programs)); a stage not written in Nx runs on the BEAM. `VisionCore.Stereo.Stage.Decode` replaces Rectification in a list without one: it only converts and shrinks the frames.

## See also

- [Where depth is computed](./compute.md)
- [Vision performance](./performance.md)
- [Vision unit](./overview.md#dashboard-and-api): editing and saving settings from the dashboard.
