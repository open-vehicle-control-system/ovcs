//! `VisionCore.Stereo.Stage.Depth` and `PointCloud`: the metric depth, and
//! the decimated cloud of the points 5 cm to 20 m away.

use crate::parallel::{on_threads, RowQueue, Shared};

/// The farthest depth `u16` millimetres hold.
const MAX_DEPTH_MM: f32 = 65_535.0;

/// The depth `focal_length_px` × `baseline_m` / `disparity` as rounded
/// millimetres and as metres, 0 where unmatched; the millimetres are 0 too
/// beyond `MAX_DEPTH_MM`. Rows are taken by `threads` threads as they come.
pub fn depth(
    disparity: &[f32],
    width: usize,
    focal_length_px: f32,
    baseline_m: f32,
    threads: usize,
) -> (Vec<u16>, Vec<f32>) {
    let focal_baseline = focal_length_px * baseline_m;
    let (mut depth_mm, mut depth_m) = (vec![0u16; disparity.len()], vec![0f32; disparity.len()]);
    let rows = RowQueue::new(disparity.len() / width);
    let (millimetres, metres) = (Shared::new(&mut depth_mm), Shared::new(&mut depth_m));
    on_threads(threads, &|_thread| {
        while let Some(range) = rows.take() {
            let pixels = range.start * width..range.end * width;
            // SAFETY: the queue hands each row to one thread.
            let (millimetres, metres) = unsafe {
                (
                    millimetres.slice_mut(pixels.clone()),
                    metres.slice_mut(pixels.clone()),
                )
            };
            for ((&pixel_disparity, metres), millimetres) in
                disparity[pixels].iter().zip(metres).zip(millimetres)
            {
                *metres = if pixel_disparity > 0.0 {
                    focal_baseline / pixel_disparity
                } else {
                    0.0
                };
                let rounded = (*metres * 1000.0).round();
                *millimetres = if rounded > MAX_DEPTH_MM {
                    0
                } else {
                    rounded.clamp(0.0, MAX_DEPTH_MM) as u16
                };
            }
        }
    });
    (depth_mm, depth_m)
}

/// The nearest and farthest depths the cloud keeps, exclusive.
const MIN_DEPTH_M: f32 = 0.05;
const MAX_DEPTH_M: f32 = 20.0;

/// The camera values the cloud unprojects with.
pub struct Intrinsics {
    pub focal_length_px: f32,
    pub cx: f32,
    pub cy: f32,
}

/// The `height / decimation` x `width / decimation` grid of `x, y, z`
/// points, each unprojected from the pixel it samples, on every
/// `decimation`-th row and column from the first, NaN outside the kept
/// depths, and how many are kept.
pub fn cloud(
    depth_m: &[f32],
    width: usize,
    height: usize,
    decimation: usize,
    intrinsics: &Intrinsics,
) -> (Vec<f32>, usize) {
    let (grid_width, grid_height) = (width / decimation, height / decimation);
    let mut points = Vec::with_capacity(3 * grid_width * grid_height);
    let mut kept = 0;
    for y in (0..grid_height).map(|row| row * decimation) {
        let v = y as f32;
        for x in (0..grid_width).map(|column| column * decimation) {
            let z = depth_m[y * width + x];
            if z > MIN_DEPTH_M && z < MAX_DEPTH_M {
                let u = x as f32;
                let z_over_focal_length = z / intrinsics.focal_length_px;
                points.extend([
                    (u - intrinsics.cx) * z_over_focal_length,
                    (v - intrinsics.cy) * z_over_focal_length,
                    z,
                ]);
                kept += 1;
            } else {
                points.extend([f32::NAN; 3]);
            }
        }
    }
    (points, kept)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn depth_is_focal_length_times_baseline_over_disparity() {
        let (millimetres, metres) = depth(&[10.0, 0.0, -1.0, 1.0e-4], 2, 100.0, 0.1, 2);
        assert_eq!(metres[..3], [1.0, 0.0, 0.0]);
        assert_eq!(millimetres, [1000, 0, 0, 0]);
    }

    #[test]
    fn a_depth_beyond_what_u16_millimetres_hold_is_no_depth() {
        // f·B is 65.535 px·m: 1 px is 65535 mm.
        let (millimetres, _metres) = depth(&[1.0, 0.9999], 2, 65_535.0, 0.001, 1);
        assert_eq!(millimetres, [65_535, 0]);
    }

    #[test]
    fn the_cloud_keeps_points_in_range_on_a_decimated_grid() {
        let intrinsics = Intrinsics {
            focal_length_px: 2.0,
            cx: 1.0,
            cy: 0.0,
        };
        let depth_m = [2.0, 9.0, 30.0, 9.0, 9.0, 9.0, 0.0, 9.0];
        let (points, kept) = cloud(&depth_m, 4, 2, 2, &intrinsics);
        assert_eq!(kept, 1);
        assert_eq!(&points[..3], &[-1.0, 0.0, 2.0]);
        assert!(points[3..].iter().all(|value| value.is_nan()));
    }

    #[test]
    fn each_point_is_unprojected_from_the_pixel_it_samples() {
        let intrinsics = Intrinsics {
            focal_length_px: 2.0,
            cx: 0.0,
            cy: 0.0,
        };
        // 4-row steps fit twice in 11 rows, with a remainder; each row its own depth.
        let (width, height) = (8, 11);
        let depth_m: Vec<f32> = (0..width * height)
            .map(|pixel| 1.0 + (pixel / width) as f32)
            .collect();
        let (points, kept) = cloud(&depth_m, width, height, 4, &intrinsics);
        assert_eq!(kept, 4);
        // The second row of points: the depth of row 4, unprojected at row 4.
        assert_eq!(&points[6..12], &[0.0, 10.0, 5.0, 10.0, 10.0, 5.0]);
    }
}
