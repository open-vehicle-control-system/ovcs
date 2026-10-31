//! `NxStereo.Rectify.rectify/3`: undistortion, rectification and shrinking
//! to the working size, one bilinear sample per pixel. The sampling map is
//! computed with the same `f32` operations in the same order, once per
//! camera model rather than per pair, and the sampling likewise, so the
//! images are those of the Nx stage.

use crate::parallel::{on_threads, RowQueue, Shared};

/// A camera as `NxStereo.Rectify.camera/4` builds it, after
/// `VisionCore.Stereo.Stage.Rectification` has moved its rows: the camera
/// matrix, the five plumb_bob coefficients and the inverse of the rectified
/// camera matrix times the rectifying rotation, row-major.
#[derive(Clone, Debug, PartialEq)]
pub struct Camera {
    pub k: [f32; 9],
    pub d: [f32; 5],
    pub inverse_pr: [f32; 9],
}

/// Where each rectified pixel samples the frame: the top-left neighbour and
/// the weights of the right and lower ones.
pub struct Map {
    width: usize,
    height: usize,
    columns: Vec<i32>,
    rows: Vec<i32>,
    column_weights: Vec<f32>,
    row_weights: Vec<f32>,
}

impl Map {
    /// The map of a `size` (`width`, `height`) image rectified from a frame
    /// of `frame_size`.
    pub fn new(camera: &Camera, size: (usize, usize), frame_size: (usize, usize)) -> Map {
        let (width, height) = size;
        let scale_x = (frame_size.0 as f64 / width as f64) as f32;
        let scale_y = (frame_size.1 as f64 / height as f64) as f32;
        let pixels = width * height;
        let mut map = Map {
            width,
            height,
            columns: Vec::with_capacity(pixels),
            rows: Vec::with_capacity(pixels),
            column_weights: Vec::with_capacity(pixels),
            row_weights: Vec::with_capacity(pixels),
        };
        for v in 0..height {
            for u in 0..width {
                let (map_x, map_y) = project(camera, u as f32, v as f32);
                let source_x = (map_x + 0.5) * scale_x - 0.5;
                let source_y = (map_y + 0.5) * scale_y - 0.5;
                let (x0, y0) = (source_x.floor(), source_y.floor());
                map.columns.push(x0 as i32);
                map.rows.push(y0 as i32);
                map.column_weights.push(source_x - x0);
                map.row_weights.push(source_y - y0);
            }
        }
        map
    }

    /// Row `v` of the rectified image of `frame`, a `frame_width` wide image.
    fn rectify_row(&self, frame: &[u8], frame_width: usize, v: usize, out: &mut [u8]) {
        let frame_height = frame.len() / frame_width;
        let row = v * self.width..(v + 1) * self.width;
        let sample = |x: i32, y: i32| -> f32 {
            if x >= 0 && (x as usize) < frame_width && y >= 0 && (y as usize) < frame_height {
                f32::from(frame[y as usize * frame_width + x as usize])
            } else {
                0.0
            }
        };
        for ((((out, &x0), &y0), &fx), &fy) in out
            .iter_mut()
            .zip(&self.columns[row.clone()])
            .zip(&self.rows[row.clone()])
            .zip(&self.column_weights[row.clone()])
            .zip(&self.row_weights[row])
        {
            let inside = x0 >= 0
                && (x0 as usize + 1) < frame_width
                && y0 >= 0
                && (y0 as usize + 1) < frame_height;
            let [top_left, top_right, bottom_left, bottom_right] = if inside {
                let at = y0 as usize * frame_width + x0 as usize;
                [
                    f32::from(frame[at]),
                    f32::from(frame[at + 1]),
                    f32::from(frame[at + frame_width]),
                    f32::from(frame[at + frame_width + 1]),
                ]
            } else {
                [
                    sample(x0, y0),
                    sample(x0 + 1, y0),
                    sample(x0, y0 + 1),
                    sample(x0 + 1, y0 + 1),
                ]
            };
            let top = (1.0 - fx) * top_left + fx * top_right;
            let bottom = (1.0 - fx) * bottom_left + fx * bottom_right;
            let value = (1.0 - fy) * top + fy * bottom;
            *out = value.round().clamp(0.0, 255.0) as u8;
        }
    }
}

/// `NxStereo.Rectify`'s projection of rectified pixel `u`, `v` into the
/// frame, operation for operation as `Nx.Defn` builds its expression.
fn project(camera: &Camera, u: f32, v: f32) -> (f32, f32) {
    let ir = &camera.inverse_pr;
    let x = ir[0] * u + ir[1] * v + ir[2];
    let y = ir[3] * u + ir[4] * v + ir[5];
    let w = ir[6] * u + ir[7] * v + ir[8];
    let (x, y) = (x / w, y / w);

    let d = &camera.d;
    let r2 = x * x + y * y;
    // The order Nx.Defn's expression sums `1 + d0 r2 + d1 r2² + d4 r2³` in.
    let radial = 1.0 + (d[4] * r2 * r2 * r2 + (d[1] * r2 * r2 + d[0] * r2));
    let xd = x * radial + 2.0 * d[2] * x * y + d[3] * (r2 + 2.0 * x * x);
    let yd = y * radial + d[2] * (r2 + 2.0 * y * y) + 2.0 * d[3] * x * y;

    let k = &camera.k;
    (k[0] * xd + k[1] * yd + k[2], k[4] * yd + k[5])
}

/// Rectifies the left and right frames into `left` and `right`, rows taken
/// by `threads` threads as they come.
pub fn rectify_pair(
    maps: [&Map; 2],
    frames: [&[u8]; 2],
    frame_width: usize,
    outs: [&mut [u8]; 2],
    threads: usize,
) {
    let height = maps[0].height;
    let width = maps[0].width;
    let rows = RowQueue::new(2 * height);
    let [left, right] = outs;
    let outs = [Shared::new(left), Shared::new(right)];
    on_threads(threads, &|_thread| {
        while let Some(range) = rows.take() {
            for row in range {
                let (side, v) = (row / height, row % height);
                // SAFETY: the queue hands each row to one thread.
                let out = unsafe { outs[side].slice_mut(v * width..(v + 1) * width) };
                maps[side].rectify_row(frames[side], frame_width, v, out);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(width: usize, height: usize) -> Camera {
        let (cx, cy) = (width as f32 / 2.0, height as f32 / 2.0);
        // The inverse of K = [[100, 0, cx], [0, 100, cy], [0, 0, 1]].
        Camera {
            k: [100.0, 0.0, cx, 0.0, 100.0, cy, 0.0, 0.0, 1.0],
            d: [0.0; 5],
            inverse_pr: [
                0.01,
                0.0,
                -cx / 100.0,
                0.0,
                0.01,
                -cy / 100.0,
                0.0,
                0.0,
                1.0,
            ],
        }
    }

    #[test]
    fn an_identity_camera_copies_the_frame() {
        let (width, height) = (16, 8);
        let frame: Vec<u8> = (0..width * height).map(|i| (i * 7 % 256) as u8).collect();
        let map = Map::new(&identity(width, height), (width, height), (width, height));
        let (mut left, mut right) = (vec![0; width * height], vec![0; width * height]);
        rectify_pair(
            [&map, &map],
            [&frame, &frame],
            width,
            [&mut left, &mut right],
            3,
        );
        assert_eq!(left, frame);
        assert_eq!(right, frame);
    }

    #[test]
    fn halving_the_size_averages_each_square_of_four() {
        let (width, height) = (8, 4);
        let frame: Vec<u8> = (0..2 * width * 2 * height)
            .map(|i| (i % 2 * 100) as u8)
            .collect();
        let map = Map::new(
            &identity(width, height),
            (width, height),
            (2 * width, 2 * height),
        );
        let (mut left, mut right) = (vec![0; width * height], vec![0; width * height]);
        rectify_pair(
            [&map, &map],
            [&frame, &frame],
            2 * width,
            [&mut left, &mut right],
            2,
        );
        // Away from the right and bottom edges, which blend with the zero border.
        assert_eq!(left[width + 1], 50);
    }
}
