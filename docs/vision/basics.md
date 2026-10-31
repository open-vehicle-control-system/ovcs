---
title: Stereo vision basics
description: How two cameras measure distance, explained from the lens up, with the vocabulary the vision unit uses (focal length, baseline, rectification, disparity, depth, point cloud) and the numbers that decide range and precision.
---

The vision unit measures distance the way your two eyes do: it compares what two cameras side by side see. This guide explains the principle and the words used everywhere else in this section, with diagrams and one worked example. The stages that implement it are in [Stereo stages](./stages.md).

The worked example is two Raspberry Pi HQ Cameras with 8 mm lenses, mounted 8 cm apart, delivering 480 × 270 images. The same formulas apply to your own cameras with their own numbers.

## One camera: the lens and the focal length

A camera turns a point in the world into a pixel. The lens acts like a pinhole: light from a point goes straight through the lens centre to the sensor. The sensor sits behind the lens and gets an upside-down image; the diagrams here draw the image plane in front of the lens instead, at the same distance `f`, which gives the same geometry without the flip.

```text
                   image plane
                        |                            * P
                        |                       .    |
                        |                  .         |
                        |             .              |  X  (P's offset
                        |        .                   |      from the axis)
                        * x .                        |
                   .    |                            |
     lens centre  o-----+----------------------------+----  optical axis
                  |< f >|                            |
                  |<------------------ Z ----------->|
```

The two triangles have the same shape, so:

```text
x = f × X / Z
```

**Focal length `f`** is the distance between the lens and the sensor. A lens is sold by its focal length in millimetres; stereo works with it **in pixels**: millimetres divided by the size of one pixel.

| Worked example | Value |
|---|---|
| Lens | 8 mm |
| HQ Camera pixel | 1.55 µm, so f = 8 / 0.00155 = 5161 px on the full 4056-pixel-wide sensor |
| Image delivered | 480 px wide, the full sensor width scaled down 8.45 times, so f = 5161 / 8.45 = **610.8 px** |
| Field of view | 2 × atan(sensor width / 2f) = 2 × atan(6.287 / 16) = **43° wide**, 24° high in the 16:9 mode |

Three things follow:

- **The field of view comes from the lens and the sensor**, not the image size. A longer lens sees a narrower cone, with more pixels per degree.
- **`f` in pixels scales with the image width.** Halve the image and `f` halves too: each pixel then covers twice the angle.
- **Real lenses bend straight lines**, mostly near the edges (distortion). Calibration measures that bending so it can be undone.

## Two cameras: the baseline

Put two identical cameras side by side, facing the same way. The distance between their lens centres is the **baseline `B`**: 8 cm in the example.

```text
  seen from above
                                  * P
                                 /|\
                                / | \
                               /  |  \
                              /   |   \
                             /    |    \
    image planes  ----------*-----|-----*----------
    at distance f          / xL   |  xR  \
                          /       Z       \
                         /        |        \
               left lens o--------+--------o right lens
                         |<------ B ------>|
```

Each camera sees `P` at a different horizontal position in its image, measured from that image's centre: `xL` in the left one, `xR` in the right one. Their difference is the **disparity**:

```text
d = xL − xR                    (in pixels)
```

From the triangles of both cameras:

```text
Z = f × B / d
```

That one formula is stereo vision. The product **`f × B`** characterises a stereo pair; in the example it is 610.8 px × 0.08 m = **48.9 px·m**.

| Distance `Z` | Disparity `d = f × B / Z` |
|---|---|
| 0.5 m | 97.7 px |
| 1 m | 48.9 px |
| 2 m | 24.4 px |
| 5 m | 9.8 px |
| 10 m | 4.9 px |

**Near objects shift a lot between the two images, far objects hardly at all.** A point infinitely far away has a disparity of zero.

## Range: the nearest point

The matcher looks for each pixel's partner over a fixed number of positions, `num_disparities`. A shift larger than that cannot be found, so the nearest measurable distance is:

```text
Z_min = f × B / num_disparities
```

| `num_disparities` | Nearest distance, example pair |
|---|---|
| 64 | 0.76 m |
| 96 | 0.51 m |
| 128 | 0.38 m |

At 64, an object at 0.5 m (97.7 px of disparity) is not measured, or worse, matched to a wrong position. More disparities cost proportionally more computing. There is also a blind band: the leftmost `num_disparities` columns of the left image have no partner in the right one, so they get no depth.

## Precision: why far is hard

Matching finds a disparity to a fraction of a pixel, never exactly. One pixel of disparity error moves the depth by:

```text
ΔZ ≈ Z² / (f × B)              per pixel of disparity error
```

| Distance | Depth error per pixel of disparity, example pair |
|---|---|
| 1 m | 2 cm |
| 2 m | 8 cm |
| 3 m | 18 cm |
| 5 m | 51 cm |

The error grows with the **square** of the distance. Matching refines disparities to a fraction of a pixel, so real errors are smaller, but the shape stays: a stereo pair is precise near and coarse far.

## Choosing lens and baseline

Range and precision both come from `f × B`:

| Change | Far precision | Nearest distance | Also |
|---|---|---|---|
| Longer lens (larger `f`) | better | farther | narrower field of view |
| Wider baseline (larger `B`) | better | farther | more surfaces seen by only one camera |
| Larger image (larger `f` in pixels) | better | farther | more pixels to match: slower |
| More `num_disparities` | same | nearer | slower |

For a vehicle that must stop for obstacles between 0.5 and 3 m, a short `f × B` and enough disparities matter more than far precision; for mapping farther away, the opposite.

## Rectification: making the search one row

To find `P`'s partner, the matcher would have to search the whole right image. Two things make it a search along one row instead.

**Epipolar geometry.** When the cameras are perfectly side by side and parallel, a point lies on the same row in both images. Real cameras are never mounted that precisely, and their lenses bend the image.

**Rectification** fixes both. From the calibration, it computes for each camera an image transform that undoes the lens distortion and rotates the image as if the two cameras were perfectly parallel. After it, a point lies on the same row in both images:

```text
  before rectification: P sits on different rows

     left image                 right image
     +------------------+       +------------------+
     |        P         |       |                  |
     |                  |       |     P            |
     +------------------+       +------------------+

  after rectification: P sits on the same row in both

     left image                 right image
     +------------------+       +------------------+
     |        P         |       |     P            |
     |                  |       |                  |
     +------------------+       +------------------+
              <---- search along this row only ---->
```

The dashboard's Row alignment figure checks this on every pair: if a camera or a lens moves after calibration, points drift off their rows and depth degrades.

## Calibration

Calibration measures each camera and their relation, usually by showing them a checkerboard of known size from many angles. It produces, per camera, in a `camera_info` YAML:

| Term | Meaning |
|---|---|
| Intrinsics `fx`, `fy`, `cx`, `cy` | Focal length in pixels, horizontally and vertically, and the image centre where the optical axis lands. |
| Distortion | How the lens bends the image (`plumb_bob`: three radial and two tangential coefficients). |
| Rectification matrix `R` | The rotation that makes the two cameras parallel. |
| Projection matrix `P` | The rectified camera. For the right camera, `P[0,3] = −fx × B`: the baseline is stored there. |

A calibration is valid for one lens setting: refocusing a lens changes its focal length and needs a new calibration. Changing the image **size** while keeping its aspect ratio does not: the pipeline scales the calibration. Changing the aspect ratio, for example from a 4:3 to a 16:9 sensor mode, needs a new one.

## Disparity map, depth image, point cloud

Matching every pixel gives three views of the same measurement:

```text
  rectified pair ──► disparity map ──► depth image ──► point cloud
                     d per pixel       Z per pixel     (X, Y, Z) per pixel
                     (pixels)          (millimetres)   (metres)
```

**Disparity map.** An image whose pixels are disparities, in pixels: large values are near. Pixels without a reliable match are marked unmatched. It is what the matcher computes.

**Depth image.** The same image with each disparity turned into a distance, `Z = f × B / d`. The unit publishes it in millimetres as 16-bit integers, 0 meaning "no measurement": the ROS convention, which consumers such as costmaps read directly.

**Point cloud.** Each depth pixel `(u, v)` with depth `Z` becomes a 3D point, reversing the camera projection:

```text
X = (u − cx) × Z / f           sideways, positive to the right
Y = (v − cy) × Z / f           vertical, positive downwards
Z                              forward, along the optical axis
```

The axes are the camera's **optical frame**: x right, y down, z forward, in metres, from the left camera's lens. ROS places this frame on the vehicle with a transform from the camera's mounting position. The unit's cloud is **organized**: it keeps the image's grid, one point every few pixels (`decimation`), with NaN where nothing was measured, so a consumer knows which pixel each point came from.

## What stereo needs from the scene

Stereo matches **texture**: small patterns of light and dark that can be told apart. Some scenes defeat it:

| Scene | What happens |
|---|---|
| Plain walls, sky, smooth floors | No texture to match: no depth (holes). |
| Repetitive patterns: fences, tiles, shelving | Several positions look alike: wrong matches, often read as obstacles too near. The matcher's `uniqueness` setting rejects many of them. |
| Reflections, glass, water | The reflection is matched at the reflected object's distance. |
| Edges of near objects | One camera sees background the other cannot (occlusion): no depth along those edges. |
| Darkness | The cameras raise their gain and lengthen their exposure: noise and motion blur, fewer matches. |
| Motion with unsynchronised cameras | The two images are taken at different instants: at 1 m/s, 33 ms apart means 3.3 cm of movement, read as a false disparity. The cameras' frame starts are synchronised for that reason. |

Filters after matching (median, speckle, temporal) remove isolated wrong pixels; [Stereo stages](./stages.md) describes each one.

## Words used in this section

| Word | Meaning |
|---|---|
| Baseline `B` | Distance between the two lens centres, in metres. |
| Focal length `f` | Lens-to-sensor distance, in pixels for stereo. |
| Rectification | Undistorting and aligning both images so that matching points share a row. |
| Disparity `d` | Horizontal shift of a point between the left and right rectified images, in pixels. |
| Depth `Z` | Distance along the optical axis, `f × B / d`. |
| Disparity map, depth image | Images of `d` and of `Z` per pixel. |
| Point cloud | The depth turned into 3D points in the camera's optical frame. |
| Matching size | The image size the stereo stages work at, which can be smaller than the cameras deliver. |
| Unmatched pixel | A pixel with no reliable partner: no disparity, no depth. |
| `camera_info` | The ROS message, and YAML file, carrying a camera's calibration. |

## See also

- [Stereo stages](./stages.md): how the unit computes each step.
- [Vision performance](./performance.md): the cost of resolution and disparities.
- [Vision unit](./overview.md)
