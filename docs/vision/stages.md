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
| 1 | [Rectification](../../vision/core/lib/vision_core/stereo/stage/rectification.ex) | camera frames | `left`, `right` | Undistorted, rectified grey images at the working size |
| 2 | [Sharpness](../../vision/core/lib/vision_core/stereo/stage/sharpness.ex) | `left`, `right` | `sharpness` | Compares the cameras' focus |
| 3 | [Disparity](../../vision/core/lib/vision_core/stereo/stage/disparity.ex) | `left`, `right` | `disparity`, `disparity_range` | Semi-global matching |
| 4 | [SpeckleFilter](../../vision/core/lib/vision_core/stereo/stage/speckle_filter.ex) | `disparity` | `disparity` | Removes small unsupported islands |
| 5 | [RowAlignment](../../vision/core/lib/vision_core/stereo/stage/row_alignment.ex) | `left`, `right`, `disparity` | `alignment` | Checks the calibration still fits |
| 6 | [TemporalFilter](../../vision/core/lib/vision_core/stereo/stage/temporal_filter.ex) | `disparity` | `disparity` | Smooths over time |
| 7 | [Depth](../../vision/core/lib/vision_core/stereo/stage/depth.ex) | `disparity` | `depth`, `disparity_bytes` | Disparity to millimetres |
| 8 | [PointCloud](../../vision/core/lib/vision_core/stereo/stage/point_cloud.ex) | depth in metres | `cloud` | Decimated 3D points |
| 9 | [Quality](../../vision/core/lib/vision_core/stereo/stage/quality.ex) | `disparity` | metrics | Statistics for the log line |

Below, **the device** is wherever the stages run: the GPU on the C100 and the VENTUNO Q, the `stereo_match` Port on the Pi 5. Values that stay on the device are not sent back to the BEAM.

A setting is either **live** or **build**:

- **Live** settings change while the unit runs, from the dashboard or as ROS 2 parameters under `<prefix>.<stage>.<setting>`, where the prefix is the component's `:prefix`, `stereo` by default (`stereo.disparity.p1`). They apply from the next pair; with native stages, from the second pair after the change, since one pair is already in the Port ([Two pairs in flight](./data_flow.md#two-pairs-in-flight)).
- **Build** settings are fixed when the pipeline starts, because they decide the shape of what it computes. You set them in your composer, for example `Pipeline.default_stages(disparity: [num_disparities: 128])`. The dashboard shows them locked.

The defaults and accepted values of each setting are in its stage's module, linked from the table above, and on the dashboard's panel. A composer option a stage does not have, a value outside what it accepts, or a `default_stages/1` override that names no stage is refused at start rather than ignored.

The costs below were measured on a Raspberry Pi 5 matching 480 × 270 with 64 disparities over 3 paths, while both cameras captured at 30 frames a second: the median time of each stage in the `stereo_match` Port. [Vision performance](./performance.md) has the full measurements.

### 1. Rectification

Undistorts and rectifies both camera frames with each camera's calibration, so a point lies on the same row in both, and shrinks frames larger than the working size in the same pass; frames smaller than the working size are refused at start. Each output pixel is one bilinear sample of the camera frame, read through a sampling map computed once per calibration.

| Setting | Kind | Meaning |
|---|---|---|
| `right_row_offset` | live | Rows the right image is moved by: a correction for cameras that have shifted since the calibration. |

`VisionCore.Stereo.AlignmentCorrection` sets `right_row_offset` for you, on by default (`:align_correction` on the `:stereo` component): when RowAlignment keeps reading an offset beyond a tenth of a row, it moves the right image, up to six rows. It corrects rows only; a camera that moved sideways needs a new calibration. Its switch, `auto_row_offset`, sits next to `right_row_offset` in the Rectification settings: switch it off to keep the offset it reached, or one you set by hand.

The calibrations are inputs, not compiled in, so a new calibration needs no rebuild. Cost on the Pi 5: about 6 ms.

### 2. Sharpness

Measures how sharp each rectified image is: the mean squared difference between horizontal neighbours, divided by the square of the mean grey so that a brightness difference between the cameras does not count. The absolute value depends on the scene; the ratio between the two cameras tells you whether one is out of focus. A pair of neighbours counts only where neither pixel is black: Rectification writes black wherever it samples outside the camera frame, such as the rows `right_row_offset` moves out of it and the wedges a turned calibration leaves at the edges, and pixels the camera itself saw as black are left out with them. Both means are over the pairs an image counts, and an image without any reads 0. The dashboard shows it next to the synchronisation. Cost: under 1 ms.

### 3. Disparity

Matches the rectified pair with **semi-global matching** (SGM), the algorithm of [libSGM](https://github.com/fixstars/libSGM), through `NxStereo.sgm/3`:

1. **Census transform.** Each pixel becomes a 48-bit signature of its 9 × 7 neighbourhood: one bit for each neighbour off the centre's row and column, set when the neighbour is more than one grey level darker than the centre. Signatures compare brightness within one image, so they survive brightness differences between the cameras.
2. **Matching cost.** For each pixel and each candidate disparity, the cost is the number of differing bits between the left signature and the right one at that shift: a Hamming distance, 0 to 48.
3. **Aggregation.** A pixel's cost alone is noisy. SGM adds, along several straight paths across the image, the best cost of the previous pixel on the path, plus a penalty `p1` when the disparity changes by one and `p2` when it jumps further. This makes neighbouring pixels agree except at real edges.
4. **Selection.** Each pixel takes the disparity with the lowest total, refined to a fraction of a pixel from its two neighbours' costs. It is dropped when the second-best total is not at least `uniqueness` times higher, which rejects ambiguous matches on repetitive or textureless surfaces.
5. **Consistency.** The match is repeated from the right image's point of view, and a pixel whose two matches disagree is dropped: typically a pixel the right camera cannot see. A 3 × 3 median ends the stage.

Matched pixels carry a positive disparity, unmatched ones −1. A match at disparity 0, which `NxStereo.sgm/3` finds on points too far to measure and in the leftmost columns, has no depth, so this stage marks it unmatched.

The 3 × 3 median is the only one in the default list; [a wider one can be added](#adding-a-wider-median-filter).

| Setting | Kind | Meaning |
|---|---|---|
| `num_disparities` | build | Positions searched. Sets the nearest measurable distance. |
| `paths` | build | Aggregation paths. 3 paths (left to right, right to left, top to bottom) take much less time than 8, on a GPU about a quarter, and leave more pixels unmatched on dark or textureless surfaces. |
| `p1` | live | Penalty for a disparity change of one pixel between neighbours. |
| `p2` | live | Penalty for a larger change, above `p1`. Higher makes surfaces smoother and edges blurrier. |
| `uniqueness` | live | How much better than the second-best match the best must be. Higher drops more ambiguous pixels. |
| `search` | build | `full` searches every disparity; `coarse_to_fine` matches the pair shrunk 2x, then searches each pixel near that match at full size: a fraction of the cost, though a structure too thin for the shrunk pair can take the background's disparity. It needs 128 disparities and runs compiled, not natively. |
| `coarse_paths` | build | With `coarse_to_fine`, the half-size match's paths, `paths` by default. It only places each pixel's search, so 3 costs little. |
| `band` | build | With `coarse_to_fine`, the disparities searched around each pixel's coarse match: 8, 16, 32 or 64. Wider costs more memory and time. |
| `margin` | build | With `coarse_to_fine`, how many of the `band` disparities lie below the coarse match. |

The settings are nx_stereo's: [`NxStereo.Stage.Disparity`](https://github.com/Spin42/nx_stereo/blob/main/lib/nx_stereo/stage/disparity.ex) declares them, and a new one there becomes a parameter here. `:fine_census`, the fine search's Census window, is given in the composer only. `:matcher` (`:native` or `:nx`), given in the composer, makes this stage run natively or compiled whatever the rest of the pipeline does. Cost on the Pi 5: about 30 ms, two thirds of the pipeline.

### 4. SpeckleFilter

Drops speckles: small islands of disparity that agree with nothing around them, typically false matches on reflections or fine repetitive structure. A matched pixel is kept when at least `min_support` of the 48 other pixels in its 7 × 7 neighbourhood matched within `max_diff` pixels of it. Islands smaller than about 4 × 4 lose their support; surfaces keep theirs up to their corners. It plays the part of OpenCV's `filterSpeckles`, which labels connected regions instead, a poor fit for a GPU.

| Setting | Kind | Meaning |
|---|---|---|
| `min_support` | live | Neighbours that must agree; 0 turns the filter off. |
| `max_diff` | live | How close, in pixels, a neighbour must be. |

Cost: about 3 ms.

### 5. RowAlignment

Measures how well the rectified images line up. A calibration that no longer fits the cameras, because a camera or a lens moved, breaks that first. The matched pixels of one row in four are compared with the right image at their disparity on the rows 2 above to 2 below their own, in four vertical bands; the row with the lowest difference is the offset there. A band where fewer than 64 of these pixels matched, or where two rows share the lowest difference, reads no offset, and the whole image likewise. The dashboard shows it as Row alignment: within half a row is good, a larger offset means recalibrate, and offsets that change from band to band mean a rotation. Cost: under 1 ms.

### 6. TemporalFilter

Smooths the disparity over time. Where a pixel matched in this pair and the previous one, within `delta` pixels of each other, it moves `alpha` of the way from the previous value to the new one; elsewhere it takes the new value. A change within `delta` is therefore smoothed, and lags: a disparity that changes steadily by up to `alpha × delta` pixels a pair trails the matcher's by `(1 − alpha) / alpha` pairs, so an object approaching slowly reads farther than it is. Only a change beyond `delta`, such as a new edge, shows at once. A pixel that loses its match keeps its last disparity for up to `hold` pairs. On a still scene this removes most of the flicker of the subpixel estimates and the holes that come and go.

| Setting | Kind | Meaning |
|---|---|---|
| `alpha` | live | Weight of the new value; 1.0 turns smoothing off. |
| `delta` | live | Largest change, in pixels, that is smoothed. |
| `hold` | live | Pairs a lost match is held; 0 turns holding off. |

This stage carries the previous disparity from one pair to the next, on the device that runs it. Cost: about 2 ms.

### 7. Depth

Turns the disparity into depth with `Z = f × B / d`, taking `f` and `B` from the calibration. It fills the 16-bit millimetre depth the depth topic and detection use, and the 32-bit float disparity the disparity topic carries. It also computes the depth in metres for the stages after it in the same segment, PointCloud among them; that image stays on the device. Unmatched pixels have no depth (0), and so do depths beyond the 65.535 m that 16-bit millimetres hold. Cost: about 2 ms.

### 8. PointCloud

Unprojects the depth pixel of every `decimation`-th row and column into an `x, y, z` point in the left camera's optical frame, each point from the pixel it samples. Points nearer than 5 cm or farther than 20 m, and unmatched pixels, are NaN, as ROS organized clouds mark them.

| Setting | Kind | Meaning |
|---|---|---|
| `decimation` | build | Keeps one pixel in `decimation` × `decimation`. |

Cost: under 1 ms.

### 9. Quality

Measures the disparity on every pair: the share of matched pixels, the mean and spread of their disparity, and the jitter, the mean change of a pixel's disparity from one pair to the next (the matcher's noise on a still scene). A pixel is matched where its disparity is positive. In the default list it measures the final disparity, after TemporalFilter, whose held matches raise the matched share and whose smoothing lowers the jitter: with TemporalFilter's `alpha` at 1 and `hold` at 0, it measures the matcher alone. Its sums are taken on the device; only five numbers come back. The depth caption on the dashboard shows the matched share. Cost: about 1 ms.

## Adding a wider median filter

Disparity already ends with a 3 × 3 median, so the default list has no median stage of its own. [MedianFilter](../../vision/core/lib/vision_core/stereo/stage/median_filter.ex) is the one to add, after Disparity in your composer's `:stages` list, for a wider window: it replaces each disparity with the median of its neighbourhood, which removes isolated wrong pixels without blurring edges. Add it to the list itself: `default_stages/1` refuses an override for a stage it does not list.

| Setting | Kind | Meaning |
|---|---|---|
| `kernel_size` | build | Neighbourhood width, in pixels: 3 or 5. |

The median does not skip unmatched pixels: it counts them as the lowest values of the neighbourhood, as Disparity's median does. A pixel comes out unmatched when more than half of its neighbourhood is, and a hole that is mostly surrounded by matches is filled. Next to a hole, the result can be a lower disparity, which reads farther, than the median of the matched pixels alone. Cost: about 2 ms with `kernel_size` 3.

## Your own stages

A stage is a module declaring `@behaviour VisionCore.Stereo.Stage`, or `@behaviour VisionCore.Stereo.NxStage` for a stage written in Nx, which is how the pipeline recognises it; the behaviour's documentation lists the callbacks. Its optional `summary/0` and `explanation/0` are the line and the paragraph the dashboard shows on the stage's panel. Put it in your composer's `:stages` list. An Nx stage compiles into the segment around it. It can compute natively when it declares the kind of its native implementation with `native_kind/0`, as a module wrapping a default stage does with that stage's kind, adding for TemporalFilter, PointCloud, RowAlignment and SpeckleFilter their `native_constants/0`, or the pipeline stops at its first pair. With `compute: :native`, an Nx stage without one becomes a compiled segment of its own between the native ones, so the component also needs `:defn_options` and a module cache ([Where depth is computed](./compute.md#nx-the-stages-as-tensor-programs)); without a compiler, the pipeline refuses to start. `compute: :nx` or `compute: :native` among an Nx stage's own options sets where it computes, whatever the component's `:compute`, and a stage asked to compute where no backend takes it is refused at start. A stage not written in Nx runs on the BEAM. [`VisionCore.Stereo.Stage.Decode`](../../vision/core/lib/vision_core/stereo/stage/decode.ex) replaces Rectification in a list without one: it only converts and shrinks the frames.

A stage is named after the last segment of its module in snake case, `speckle_filter` for `SpeckleFilter`, and its settings are addressed by that name, `<prefix>.<stage>.<setting>`: two stages of the same name are refused at start. The unit finds the stages it treats apart by what they declare, not by name. The first stage that provides `left` and `right` shows the matching size on its panel. The stage that declares a `right_row_offset` setting is the one `VisionCore.Stereo.AlignmentCorrection` moves and a new calibration sets back to 0, with `auto_row_offset` before it in its settings; the stage that provides `alignment` is the one whose measure the correction follows, and whose panel shows the row offset. Rectification and RowAlignment are these by default, and a stage of your own that replaces one keeps its part by declaring the same. Two stages that declare `right_row_offset`, or two that provide `alignment`, are refused at start.

## See also

- [Where depth is computed](./compute.md)
- [Vision performance](./performance.md)
- [Vision unit](./README.md#dashboard-and-api): editing and saving settings from the dashboard.
