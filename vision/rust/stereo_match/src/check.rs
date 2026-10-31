//! OpenCV's left-right consistency check and the 3x3 median filter, as
//! `NxStereo` applies them after selection.

use crate::filters::MEDIAN_9;
use crate::select::INVALID_KEY;

/// One row's disparities with those rejected by the left-right check set
/// to `-1.0`. Each right pixel keeps the cheapest left match projected onto
/// it, ties favouring the larger disparity; a left pixel is rejected when
/// neither adjacent integer disparity agrees with it within one. `right` is
/// scratch space.
pub fn consistency_row(disparity: &[f32], keys: &[u32], right: &mut Vec<u32>, out: &mut [f32]) {
    let width = keys.len();
    right.clear();
    right.resize(width, INVALID_KEY);
    for (x, &key) in keys.iter().enumerate() {
        if key != INVALID_KEY {
            let winner = key & 0xFFFF;
            let candidate = (key & 0xFFFF_0000) | (65_535 - winner);
            let target = &mut right[x - winner as usize];
            *target = (*target).min(candidate);
        }
    }
    let disagrees = |right_x: i64, d: i64| {
        if right_x < 0 || right_x >= width as i64 {
            return false;
        }
        let found = right[right_x as usize];
        found != INVALID_KEY && (65_535 - i64::from(found & 0xFFFF) - d).abs() > 1
    };
    for (x, (&value, out)) in disparity.iter().zip(out.iter_mut()).enumerate() {
        *out = -1.0;
        if value >= 0.0 {
            // Floor and ceiling of a non-negative value.
            let low = value as i64;
            let high = low + i64::from(low as f32 != value);
            if !(disagrees(x as i64 - low, low) && disagrees(x as i64 - high, high)) {
                *out = value;
            }
        }
    }
}

const MEDIAN_CHUNK: usize = 64;

/// A row of the 3x3 median filter from `rows`, the row above, the row and
/// the row below, borders replicated. The values, -1.0 or non-negative,
/// are compared by their bits as `i32`, which orders them as `f32` does.
/// `keys` is scratch space.
pub fn median_row(rows: [&[f32]; 3], keys: &mut Vec<i32>, out: &mut [f32]) {
    let width = out.len();
    keys.clear();
    for row in rows {
        keys.push(row[0].to_bits() as i32);
        keys.extend(row.iter().map(|value| value.to_bits() as i32));
        keys.push(row[width - 1].to_bits() as i32);
    }
    let stride = width + 2;
    for start in (0..width).step_by(MEDIAN_CHUNK) {
        let count = MEDIAN_CHUNK.min(width - start);
        let mut values = [[0i32; MEDIAN_CHUNK]; 9];
        for (k, values) in values.iter_mut().enumerate() {
            let from = (k / 3) * stride + start + k % 3;
            values[..count].copy_from_slice(&keys[from..from + count]);
        }
        for (a, b) in MEDIAN_9 {
            for i in 0..MEDIAN_CHUNK {
                let (low, high) = (
                    values[a][i].min(values[b][i]),
                    values[a][i].max(values[b][i]),
                );
                values[a][i] = low;
                values[b][i] = high;
            }
        }
        for (out, &median) in out[start..start + count].iter_mut().zip(&values[4]) {
            *out = f32::from_bits(median as u32);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reference;
    use crate::tests::Random;

    #[test]
    fn median_matches_a_sort() {
        let (width, height) = (13, 7);
        let mut random = Random::new(5);
        let image: Vec<f32> = (0..width * height)
            .map(|_| (random.next() % 9) as f32 - 1.0)
            .collect();
        let want = reference::median3(&image, width, height);
        let mut got = vec![0.0; width * height];
        for (y, row) in got.chunks_exact_mut(width).enumerate() {
            let rows = [y.saturating_sub(1), y, (y + 1).min(height - 1)]
                .map(|y| &image[y * width..(y + 1) * width]);
            median_row(rows, &mut Vec::new(), row);
        }
        assert_eq!(got, want);
    }

    #[test]
    fn consistency_matches_the_reference() {
        let width = 90;
        let mut random = Random::new(8);
        for _ in 0..500 {
            let mut keys = vec![INVALID_KEY; width];
            let mut disparity = vec![-1.0f32; width];
            for x in 0..width {
                if !random.next().is_multiple_of(5) {
                    let winner = (random.next() % (x as u64 + 1).min(64)) as u32;
                    let cost = (random.next() % 4) as u32;
                    keys[x] = (cost << 16) | winner;
                    let fraction = [0.0, 0.3, -0.4, 0.5][(random.next() % 4) as usize];
                    disparity[x] = (winner as f32 + fraction).max(0.0);
                }
            }
            let want = reference::consistency(&disparity, &keys, width, 1, 64);
            let mut got = vec![0.0; width];
            consistency_row(&disparity, &keys, &mut Vec::new(), &mut got);
            assert_eq!(got, want);
        }
    }

    #[test]
    fn a_tie_on_a_right_pixel_favours_the_larger_disparity() {
        // Left pixels 10 (d 5) and 12 (d 7) both land on right pixel 5 at cost 3.
        let mut keys = vec![INVALID_KEY; 16];
        keys[10] = (3 << 16) | 5;
        keys[12] = (3 << 16) | 7;
        let mut disparity = vec![-1.0; 16];
        disparity[10] = 5.0;
        disparity[12] = 7.0;
        let mut out = vec![0.0; 16];
        consistency_row(&disparity, &keys, &mut Vec::new(), &mut out);
        assert_eq!((out[10], out[12]), (-1.0, 7.0));
    }
}
