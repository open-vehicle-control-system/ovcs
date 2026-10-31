//! `VisionCore.Stereo.Stage.Depth` and `PointCloud`: `NxStereo.Depth`'s
//! metric depth, and the decimated cloud of the points 5 cm to 20 m away.

use crate::parallel::{on_threads, RowQueue, Shared};

/// The depth `focal_length_px` × `baseline_m` / `disparity` as rounded
/// millimetres, saturating at 65535, and as metres; 0 where unmatched.
/// Rows are taken by `threads` threads as they come.
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
            for ((&d, metres), millimetres) in disparity[pixels].iter().zip(metres).zip(millimetres)
            {
                *metres = if d > 0.0 { focal_baseline / d } else { 0.0 };
                *millimetres = (*metres * 1000.0).round().clamp(0.0, 65_535.0) as u16;
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
/// points, one every `decimation` pixels sampled as OpenCV's nearest resize
/// does, NaN outside the kept depths, and how many are kept.
pub fn cloud(
    depth_m: &[f32],
    width: usize,
    height: usize,
    decimation: usize,
    intrinsics: &Intrinsics,
) -> (Vec<f32>, usize) {
    let (grid_width, grid_height) = (width / decimation, height / decimation);
    let source = |index: usize, size: usize, grid: usize| {
        (index as f64 * (size as f64 / grid as f64)).floor() as usize
    };
    let mut points = Vec::with_capacity(3 * grid_width * grid_height);
    let mut kept = 0;
    for row in 0..grid_height {
        let y = source(row, height, grid_height);
        let v = row as f32 * decimation as f32;
        for column in 0..grid_width {
            let z = depth_m[y * width + source(column, width, grid_width)];
            if z > MIN_DEPTH_M && z < MAX_DEPTH_M {
                let u = column as f32 * decimation as f32;
                let z_over_f = z / intrinsics.focal_length_px;
                points.extend([
                    (u - intrinsics.cx) * z_over_f,
                    (v - intrinsics.cy) * z_over_f,
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
        assert_eq!(millimetres, [1000, 0, 0, 65_535]);
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
}
