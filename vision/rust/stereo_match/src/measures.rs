//! The sums `VisionCore.Stereo.Stage.Sharpness`, `RowAlignment` and
//! `Quality` take on the device, which their `finish/3` turns into the
//! pair's measures. Image planes are summed down the columns first, then
//! across, each partial sum rounded to `f32`, as their Nx steps do.

/// `[left energy, right energy, left grey, right grey, left pairs, right
/// pairs]`: over each pair of horizontal neighbours both above black, the
/// squared difference and the grey of its left pixel, summed per image,
/// then how many such pairs each image has. Rectification writes black
/// where it samples outside the camera frame.
pub fn sharpness_sums(left: &[u8], right: &[u8], width: usize) -> [f32; 6] {
    let (left_energy, left_grey, left_pairs) = sharpness_planes(left, width);
    let (right_energy, right_grey, right_pairs) = sharpness_planes(right, width);
    [
        left_energy,
        right_energy,
        left_grey,
        right_grey,
        left_pairs,
        right_pairs,
    ]
}

fn sharpness_planes(image: &[u8], width: usize) -> (f32, f32, f32) {
    let mut energy = vec![0u64; width - 1];
    let mut grey = vec![0u64; width - 1];
    let mut pairs = vec![0u64; width - 1];
    for row in image.chunks_exact(width) {
        for (x, pair) in row.windows(2).enumerate() {
            if pair[0] > 0 && pair[1] > 0 {
                let difference = i64::from(pair[1]) - i64::from(pair[0]);
                energy[x] += (difference * difference) as u64;
                grey[x] += u64::from(pair[0]);
                pairs[x] += 1;
            }
        }
    }
    (
        sum_columns(&energy),
        sum_columns(&grey),
        sum_columns(&pairs),
    )
}

/// The column sums, each rounded to `f32`, summed and rounded again.
fn sum_columns(columns: &[u64]) -> f32 {
    columns
        .iter()
        .map(|&column| f64::from(column as f32))
        .sum::<f64>() as f32
}

/// Vertical bands the row offset is measured in.
pub const BANDS: usize = 4;
/// Rows above and below a pixel's own that it is compared with.
pub const REACH: usize = 2;
/// One row in this many is compared.
const ROW_STEP: usize = 4;
/// Per band, a sum per row offset and the matched count.
pub const PLANES: usize = 2 * REACH + 2;

/// Per vertical band, the summed absolute difference between each matched
/// left pixel of every fourth row and the right pixel at its disparity on
/// the rows `REACH` above to `REACH` below, then the matched count.
pub fn alignment_sums(
    left: &[u8],
    right: &[u8],
    disparity: &[f32],
    width: usize,
    height: usize,
) -> [[f32; PLANES]; BANDS] {
    let band_width = width / BANDS;
    let mut sums = [[0u64; PLANES]; BANDS];
    for y in (0..height).step_by(ROW_STEP) {
        for (band, sums) in sums.iter_mut().enumerate() {
            for x in band * band_width..(band + 1) * band_width {
                let value = disparity[y * width + x];
                let matched = value > 0.0;
                if !matched {
                    continue;
                }
                let source_x = (x as f32 - value.round()).clamp(0.0, (width - 1) as f32) as usize;
                let grey = i32::from(left[y * width + x]);
                for (offset, sum) in sums[..2 * REACH + 1].iter_mut().enumerate() {
                    let source_y = (y + offset).saturating_sub(REACH).min(height - 1);
                    let difference = i32::from(right[source_y * width + source_x]) - grey;
                    *sum += difference.unsigned_abs() as u64;
                }
                sums[2 * REACH + 1] += 1;
            }
        }
    }
    sums.map(|band| band.map(|sum| sum as f32))
}

/// What `Quality` carries from one pair to the next: the disparity it last
/// measured.
pub struct Quality {
    previous: Vec<f32>,
}

impl Quality {
    pub fn new(pixels: usize) -> Quality {
        Quality {
            previous: vec![-1.0; pixels],
        }
    }

    /// `[matched, sum, sum of squares, matched in both pairs, change]` of
    /// `disparity`, then remembers it.
    pub fn sums(&mut self, disparity: &[f32], width: usize) -> [f32; 5] {
        let mut columns = vec![[0f64; 5]; width];
        for (row, previous_row) in disparity
            .chunks_exact(width)
            .zip(self.previous.chunks_exact(width))
        {
            for ((columns, &current), &previous) in columns.iter_mut().zip(row).zip(previous_row) {
                let matched = if current > 0.0 { 1.0f32 } else { 0.0 };
                let both = if previous > 0.0 { 1.0f32 } else { 0.0 } * matched;
                let value = current * matched;
                let planes = [
                    matched,
                    value,
                    value * value,
                    both,
                    (current - previous).abs() * both,
                ];
                for (column, plane) in columns.iter_mut().zip(planes) {
                    *column += f64::from(plane);
                }
            }
        }
        self.previous.copy_from_slice(disparity);
        std::array::from_fn(|plane| {
            columns
                .iter()
                .map(|column| f64::from(column[plane] as f32))
                .sum::<f64>() as f32
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sharpness_sums_neighbour_differences_and_grey() {
        let image = [10u8, 13, 13, 1, 1, 5];
        assert_eq!(
            sharpness_sums(&image, &image, 3),
            [25.0, 25.0, 25.0, 25.0, 4.0, 4.0]
        );
    }

    #[test]
    fn sharpness_counts_only_neighbours_both_above_black() {
        let image = [10u8, 13, 13, 0, 0, 4];
        assert_eq!(
            sharpness_sums(&image, &[0; 6], 3),
            [9.0, 0.0, 23.0, 0.0, 2.0, 0.0]
        );
    }

    #[test]
    fn alignment_is_lowest_at_the_offset_the_right_image_is_moved_by() {
        let (width, height) = (32, 24);
        let texture = |x: usize, y: usize| ((x * 31 + y * 17 + x * y * 7) % 251) as u8;
        let left: Vec<u8> = (0..width * height)
            .map(|i| texture(i % width, i / width + 4))
            .collect();
        // The right image's rows sit one lower, three columns left.
        let right: Vec<u8> = (0..width * height)
            .map(|i| texture(i % width + 3, i / width + 3))
            .collect();
        let disparity = vec![3.0; width * height];
        let sums = alignment_sums(&left, &right, &disparity, width, height);
        for band in &sums[1..] {
            let lowest = (0..=2 * REACH)
                .min_by(|&a, &b| band[a].total_cmp(&band[b]))
                .unwrap();
            assert_eq!(lowest, REACH + 1);
            assert_eq!(
                band[2 * REACH + 1],
                (width / BANDS * height / ROW_STEP) as f32
            );
        }
    }

    #[test]
    fn alignment_counts_no_pixel_at_disparity_0() {
        let (width, height) = (32, 24);
        let image = vec![90u8; width * height];
        let sums = alignment_sums(&image, &image, &vec![0.0; width * height], width, height);
        assert_eq!(sums, [[0.0; PLANES]; BANDS]);
    }

    #[test]
    fn quality_counts_matched_pixels_and_their_change() {
        let mut quality = Quality::new(4);
        assert_eq!(
            quality.sums(&[2.0, 0.0, -1.0, 4.0], 2),
            [2.0, 6.0, 20.0, 0.0, 0.0]
        );
        assert_eq!(
            quality.sums(&[3.0, 1.0, 1.0, 4.0], 2),
            [4.0, 9.0, 27.0, 2.0, 1.0]
        );
    }
}
