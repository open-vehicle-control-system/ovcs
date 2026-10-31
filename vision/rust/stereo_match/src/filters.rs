//! The disparity filters of `VisionCore.Stereo.Stage`: `MedianFilter`,
//! `SpeckleFilter` and `TemporalFilter`, with the comparisons and `f32`
//! operations of their Nx steps.

use crate::parallel::{on_threads, RowQueue, Shared};

/// Devillard's median selection networks, as `NxStereo.Image.median/2`
/// applies them: compare-exchanges leaving the median of 9 and 25 values in
/// the middle position.
const MEDIAN_9: [(usize, usize); 19] = [
    (1, 2),
    (4, 5),
    (7, 8),
    (0, 1),
    (3, 4),
    (6, 7),
    (1, 2),
    (4, 5),
    (7, 8),
    (0, 3),
    (5, 8),
    (4, 7),
    (3, 6),
    (1, 4),
    (2, 5),
    (4, 7),
    (4, 2),
    (6, 4),
    (4, 2),
];

const MEDIAN_25: [(usize, usize); 99] = [
    (0, 1),
    (3, 4),
    (2, 4),
    (2, 3),
    (6, 7),
    (5, 7),
    (5, 6),
    (9, 10),
    (8, 10),
    (8, 9),
    (12, 13),
    (11, 13),
    (11, 12),
    (15, 16),
    (14, 16),
    (14, 15),
    (18, 19),
    (17, 19),
    (17, 18),
    (21, 22),
    (20, 22),
    (20, 21),
    (23, 24),
    (2, 5),
    (3, 6),
    (0, 6),
    (0, 3),
    (4, 7),
    (1, 7),
    (1, 4),
    (11, 14),
    (8, 14),
    (8, 11),
    (12, 15),
    (9, 15),
    (9, 12),
    (13, 16),
    (10, 16),
    (10, 13),
    (20, 23),
    (17, 23),
    (17, 20),
    (21, 24),
    (18, 24),
    (18, 21),
    (19, 22),
    (8, 17),
    (9, 18),
    (0, 18),
    (0, 9),
    (10, 19),
    (1, 19),
    (1, 10),
    (11, 20),
    (2, 20),
    (2, 11),
    (12, 21),
    (3, 21),
    (3, 12),
    (13, 22),
    (4, 22),
    (4, 13),
    (14, 23),
    (5, 23),
    (5, 14),
    (15, 24),
    (6, 24),
    (6, 15),
    (7, 16),
    (7, 19),
    (13, 21),
    (15, 23),
    (7, 13),
    (7, 15),
    (1, 9),
    (3, 11),
    (5, 17),
    (11, 17),
    (9, 17),
    (4, 10),
    (6, 12),
    (7, 14),
    (4, 6),
    (4, 7),
    (12, 14),
    (10, 14),
    (6, 7),
    (10, 12),
    (6, 10),
    (6, 17),
    (12, 17),
    (7, 17),
    (7, 10),
    (12, 18),
    (7, 12),
    (10, 18),
    (12, 20),
    (10, 20),
    (10, 12),
];

/// The median of each pixel's `kernel_size` x `kernel_size` neighbourhood
/// (3 or 5), borders replicated.
pub fn median(
    image: &[f32],
    width: usize,
    height: usize,
    kernel_size: usize,
    threads: usize,
) -> Vec<f32> {
    let mut out = vec![0.0; width * height];
    let rows = RowQueue::new(height);
    let shared = Shared::new(&mut out);
    on_threads(threads, &|_thread| {
        let mut values = Vec::new();
        let network: &[(usize, usize)] = if kernel_size == 3 {
            &MEDIAN_9
        } else {
            &MEDIAN_25
        };
        while let Some(range) = rows.take() {
            for y in range {
                // SAFETY: the queue hands each row to one thread.
                let out = unsafe { shared.slice_mut(y * width..(y + 1) * width) };
                median_row(
                    image,
                    (width, height),
                    y,
                    kernel_size,
                    network,
                    &mut values,
                    out,
                );
            }
        }
    });
    out
}

/// Row `y` of the median over the `side` x `side` window: each window
/// position's values for the whole row, then each compare-exchange of the
/// network over whole rows. `values` is scratch space.
fn median_row(
    image: &[f32],
    (width, height): (usize, usize),
    y: usize,
    side: usize,
    network: &[(usize, usize)],
    values: &mut Vec<f32>,
    out: &mut [f32],
) {
    let radius = side / 2;
    values.resize(side * side * width, 0.0);
    for (index, row) in values.chunks_exact_mut(width).enumerate() {
        let (dy, dx) = (index / side, index % side);
        let source_y = (y + dy).saturating_sub(radius).min(height - 1);
        let source = &image[source_y * width..(source_y + 1) * width];
        // Each pixel's neighbour `dx - radius` columns away, the edge repeated.
        if dx < radius {
            let shift = (radius - dx).min(width);
            row[..shift].fill(source[0]);
            row[shift..].copy_from_slice(&source[..width - shift]);
        } else {
            let shift = (dx - radius).min(width);
            row[..width - shift].copy_from_slice(&source[shift..]);
            row[width - shift..].fill(source[width - 1]);
        }
    }
    for &(a, b) in network {
        let (first, second) = values.split_at_mut(a.max(b) * width);
        let (low, high) = if a < b {
            (&mut first[a * width..(a + 1) * width], &mut second[..width])
        } else {
            (&mut second[..width], &mut first[b * width..(b + 1) * width])
        };
        for (low, high) in low.iter_mut().zip(high.iter_mut()) {
            let (smaller, larger) = (low.min(*high), low.max(*high));
            *low = smaller;
            *high = larger;
        }
    }
    out.copy_from_slice(&values[side * side / 2 * width..][..width]);
}

/// The radius of the speckle filter's window.
const SPECKLE_RADIUS: usize = 3;

/// The disparity with each matched pixel kept only where at least
/// `min_support` of the 48 others in its 7x7 window matched within
/// `max_diff` of it, unmatched (`-1.0`) outside the image.
pub fn despeckle(
    disparity: &[f32],
    width: usize,
    height: usize,
    min_support: f32,
    max_diff: f32,
    threads: usize,
) -> Vec<f32> {
    let stride = width + 2 * SPECKLE_RADIUS;
    let mut padded = vec![-1.0f32; stride * (height + 2 * SPECKLE_RADIUS)];
    for (y, row) in disparity.chunks_exact(width).enumerate() {
        let start = (y + SPECKLE_RADIUS) * stride + SPECKLE_RADIUS;
        padded[start..start + width].copy_from_slice(row);
    }
    let mut out = vec![0.0; width * height];
    let rows = RowQueue::new(height);
    let shared = Shared::new(&mut out);
    let padded = &padded;
    on_threads(threads, &|_thread| {
        let mut support = vec![0u32; width];
        while let Some(range) = rows.take() {
            for y in range {
                support.fill(0);
                let centre = &disparity[y * width..(y + 1) * width];
                for dy in 0..2 * SPECKLE_RADIUS + 1 {
                    for dx in 0..2 * SPECKLE_RADIUS + 1 {
                        if (dy, dx) == (SPECKLE_RADIUS, SPECKLE_RADIUS) {
                            continue;
                        }
                        let neighbours = &padded[(y + dy) * stride + dx..][..width];
                        for ((support, &neighbour), &centre) in
                            support.iter_mut().zip(neighbours).zip(centre)
                        {
                            let agrees =
                                (neighbour >= 0.0) & ((neighbour - centre).abs() <= max_diff);
                            *support += u32::from(agrees);
                        }
                    }
                }
                // SAFETY: the queue hands each row to one thread.
                let out = unsafe { shared.slice_mut(y * width..(y + 1) * width) };
                for ((out, &centre), &support) in out.iter_mut().zip(centre).zip(&support) {
                    let kept = centre >= 0.0 && support as f32 >= min_support;
                    *out = if kept { centre } else { -1.0 };
                }
            }
        }
    });
    out
}

/// What the temporal filter carries from one pair to the next: the last
/// filtered disparity and, per pixel, the pairs since it last matched.
pub struct Temporal {
    previous: Vec<f32>,
    missed: Vec<f32>,
}

/// The temporal filter's live settings.
pub struct TemporalSettings {
    pub alpha: f32,
    pub delta: f32,
    pub hold: f32,
}

impl Temporal {
    pub fn new(pixels: usize) -> Temporal {
        Temporal {
            previous: vec![-1.0; pixels],
            missed: vec![0.0; pixels],
        }
    }

    /// Filters `disparity` in place against the previous pair's.
    pub fn filter(&mut self, disparity: &mut [f32], settings: &TemporalSettings) {
        let TemporalSettings { alpha, delta, hold } = *settings;
        for ((current, previous), missed) in disparity
            .iter_mut()
            .zip(self.previous.iter_mut())
            .zip(self.missed.iter_mut())
        {
            let matched = *current >= 0.0;
            let agree = matched && *previous >= 0.0 && (*current - *previous).abs() <= delta;
            let smoothed = if agree {
                alpha * *current + (1.0 - alpha) * *previous
            } else {
                *current
            };
            let pairs_missed = if matched { 0.0 } else { *missed + 1.0 };
            let held = !matched && *previous >= 0.0 && pairs_missed <= hold;
            let filtered = if held { *previous } else { smoothed };
            *current = filtered;
            *previous = filtered;
            *missed = pairs_missed.min(255.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted_median(values: &mut [f32]) -> f32 {
        values.sort_by(f32::total_cmp);
        values[values.len() / 2]
    }

    #[test]
    fn median_is_the_sorted_middle_with_replicated_borders() {
        let (width, height) = (21, 9);
        let image: Vec<f32> = (0..width * height)
            .map(|i| ((i * 37 + 11) % 53) as f32 / 4.0 - 1.0)
            .collect();
        for kernel_size in [3usize, 5] {
            let radius = kernel_size as isize / 2;
            let got = median(&image, width, height, kernel_size, 3);
            for y in 0..height as isize {
                for x in 0..width as isize {
                    let mut window: Vec<f32> = (-radius..=radius)
                        .flat_map(|dy| (-radius..=radius).map(move |dx| (dy, dx)))
                        .map(|(dy, dx)| {
                            let sy = (y + dy).clamp(0, height as isize - 1) as usize;
                            let sx = (x + dx).clamp(0, width as isize - 1) as usize;
                            image[sy * width + sx]
                        })
                        .collect();
                    assert_eq!(
                        got[y as usize * width + x as usize],
                        sorted_median(&mut window),
                        "{kernel_size}x{kernel_size} at {x}, {y}"
                    );
                }
            }
        }
    }

    #[test]
    fn despeckle_drops_islands_and_keeps_surfaces() {
        let (width, height) = (20, 12);
        let mut disparity = vec![10.0; width * height];
        for y in 0..height {
            disparity[y * width + 15..(y + 1) * width].fill(-1.0);
        }
        disparity[5 * width + 17] = 30.0;
        let got = despeckle(&disparity, width, height, 12.0, 1.0, 2);
        assert_eq!(got[5 * width + 17], -1.0);
        assert_eq!(got[0], 10.0);
        assert_eq!(got[5 * width + 5], 10.0);
        assert!(got[5 * width + 15..(5 + 1) * width]
            .iter()
            .all(|&d| d == -1.0));
    }

    #[test]
    fn temporal_smooths_agreeing_values_and_holds_lost_ones() {
        let settings = TemporalSettings {
            alpha: 0.5,
            delta: 2.0,
            hold: 1.0,
        };
        let mut temporal = Temporal::new(3);
        let mut first = [10.0, 10.0, 10.0];
        temporal.filter(&mut first, &settings);
        assert_eq!(first, [10.0, 10.0, 10.0]);
        let mut second = [11.0, 20.0, -1.0];
        temporal.filter(&mut second, &settings);
        assert_eq!(second, [10.5, 20.0, 10.0]);
        let mut third = [11.0, 20.0, -1.0];
        temporal.filter(&mut third, &settings);
        assert_eq!(third, [10.75, 20.0, -1.0]);
    }
}
