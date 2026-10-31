//! The 9x7 Census transform and the Hamming matching costs of one row.
//!
//! A row's features are kept as six byte planes, one per neighbour row of
//! the window, so the costs of a pixel are byte popcounts over contiguous
//! disparities.

/// Neighbour rows of the window, above and below the centre; each is one
/// byte of the feature, its eight columns `-4..=-1, 1..=4` in order.
const ROW_OFFSETS: [isize; 6] = [-3, -2, -1, 1, 2, 3];
const COLUMN_OFFSETS: [isize; 8] = [-4, -3, -2, -1, 1, 2, 3, 4];
pub const PLANES: usize = ROW_OFFSETS.len();
const HALF_WIDTH: usize = 4;

/// Row `y`'s features as `out[k * width + x]`: bit `j` of plane `k` set
/// where the neighbour at `ROW_OFFSETS[k]`, `COLUMN_OFFSETS[j]` is more than
/// one level below the centre, borders replicated. Plane `k` is byte `k` of
/// `NxStereo`'s 48-bit feature. `padded` is scratch space.
pub fn census_row(
    image: &[u8],
    width: usize,
    height: usize,
    y: usize,
    padded: &mut Vec<u8>,
    out: &mut [u8],
) {
    let stride = width + 2 * HALF_WIDTH;
    padded.resize(7 * stride, 0);
    for (slot, offset) in (-3..=3isize).enumerate() {
        let source_y = (y as isize + offset).clamp(0, height as isize - 1) as usize;
        let source = &image[source_y * width..(source_y + 1) * width];
        let row = &mut padded[slot * stride..(slot + 1) * stride];
        row[..HALF_WIDTH].fill(source[0]);
        row[HALF_WIDTH..HALF_WIDTH + width].copy_from_slice(source);
        row[HALF_WIDTH + width..].fill(source[width - 1]);
    }
    let centre = &padded[3 * stride + HALF_WIDTH..][..width];
    for (row_offset, plane) in ROW_OFFSETS.iter().zip(out.chunks_exact_mut(width)) {
        let row = &padded[(3 + row_offset) as usize * stride..][..stride];
        plane.fill(0);
        for (bit, column_offset) in COLUMN_OFFSETS.iter().enumerate() {
            let start = (HALF_WIDTH as isize + column_offset) as usize;
            let neighbours = &row[start..start + width];
            for ((plane, &centre), &neighbour) in plane.iter_mut().zip(centre).zip(neighbours) {
                *plane |= u8::from(centre.saturating_sub(neighbour) > 1) << bit;
            }
        }
    }
}

/// Each of the right row's planes reversed and followed by `disparities`
/// zeros, so the right features a left pixel at `x` is compared with,
/// `x - d` for `d` from 0 up, are contiguous from `width - 1 - x`, and
/// those left of the image are zero.
pub fn reverse_right(right: &[u8], width: usize, disparities: usize, reversed: &mut Vec<u8>) {
    reversed.clear();
    for plane in right.chunks_exact(width) {
        reversed.extend(plane.iter().rev());
        reversed.extend(std::iter::repeat_n(0, disparities));
    }
}

/// `out[x * D + d]`, the Hamming distance between left feature `x` and
/// right feature `x - d`, from planes as `census_row` and `reverse_right`
/// lay them out.
pub fn costs_row<const D: usize>(left: &[u8], reversed_right: &[u8], width: usize, out: &mut [u8]) {
    let reversed_stride = width + D;
    for (x, costs) in out.chunks_exact_mut(D).enumerate().take(width) {
        let costs: &mut [u8; D] = costs.try_into().unwrap();
        costs.fill(0);
        for plane in 0..PLANES {
            let feature = left[plane * width + x];
            let start = plane * reversed_stride + width - 1 - x;
            let candidates: &[u8; D] = reversed_right[start..start + D].try_into().unwrap();
            for (cost, &candidate) in costs.iter_mut().zip(candidates) {
                *cost += (feature ^ candidate).count_ones() as u8;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reference;
    use crate::tests::noise;

    fn features(planes: &[u8], width: usize) -> Vec<u64> {
        (0..width)
            .map(|x| {
                (0..PLANES)
                    .map(|k| u64::from(planes[k * width + x]) << (8 * k))
                    .sum()
            })
            .collect()
    }

    fn census(image: &[u8], width: usize, height: usize, y: usize) -> Vec<u8> {
        let mut planes = vec![0; PLANES * width];
        census_row(image, width, height, y, &mut Vec::new(), &mut planes);
        planes
    }

    #[test]
    fn features_match_the_reference() {
        let (width, height) = (37, 11);
        let image = noise(width, height, 4);
        let want = reference::census(&image, width, height);
        for y in 0..height {
            assert_eq!(
                features(&census(&image, width, height, y), width),
                want[y * width..(y + 1) * width],
                "row {y}"
            );
        }
    }

    #[test]
    fn bits_follow_nx_stereo_neighbour_order() {
        // One pixel two levels darker, two rows up and three columns right of the centre.
        let (width, height) = (9, 7);
        let mut image = vec![100u8; width * height];
        image[width + 7] = 98;
        let bit = reference::neighbours()
            .iter()
            .position(|&n| n == (-2, 3))
            .unwrap();
        assert_eq!(bit, 8 + 6);
        assert_eq!(
            features(&census(&image, width, height, 3), width)[4],
            1 << bit
        );

        let mut image = vec![100u8; width * height];
        image[3 * width + 4] = 102;
        assert_eq!(
            features(&census(&image, width, height, 3), width)[4],
            (1 << 48) - 1,
            "every neighbour two levels below"
        );
        image[3 * width + 4] = 101;
        assert_eq!(
            features(&census(&image, width, height, 3), width)[4],
            0,
            "one level below does not count"
        );
    }

    #[test]
    fn costs_match_the_reference() {
        let (width, height) = (70, 9);
        let (left, right) = (noise(width, height, 1), noise(width, height, 2));
        let want: Vec<u8> = reference::matching_costs(
            &reference::census(&left, width, height),
            &reference::census(&right, width, height),
            width,
            height,
            64,
        )
        .iter()
        .map(|&c| c as u8)
        .collect();
        let mut reversed = Vec::new();
        let mut got = vec![0; width * 64];
        for y in 0..height {
            reverse_right(&census(&right, width, height, y), width, 64, &mut reversed);
            costs_row::<64>(&census(&left, width, height, y), &reversed, width, &mut got);
            assert_eq!(got, want[y * width * 64..(y + 1) * width * 64], "row {y}");
        }
    }
}
