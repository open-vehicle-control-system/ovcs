//! Grey frames from the luma plane of the ISP's YUV420 output.

/// The first `width` bytes of each of `height` rows `stride` bytes apart, into `grey`.
pub fn pack_luma(grey: &mut Vec<u8>, luma: &[u8], width: usize, height: usize, stride: usize) {
    grey.clear();
    if stride == width {
        grey.extend_from_slice(&luma[..width * height]);
    } else {
        for row in luma.chunks(stride).take(height) {
            grey.extend_from_slice(&row[..width]);
        }
    }
}

/// Bytes of a plane of `height` rows `stride` apart whose last row holds `width` pixels.
pub fn luma_length(width: usize, height: usize, stride: usize) -> usize {
    if height == 0 {
        0
    } else {
        stride * (height - 1) + width
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_the_padding_after_each_row() {
        let luma = [1, 2, 3, 0xee, 4, 5, 6, 0xee, 7, 8, 9];
        let mut grey = Vec::new();
        pack_luma(&mut grey, &luma, 3, 3, 4);
        assert_eq!(grey, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }

    #[test]
    fn copies_a_packed_plane_whole() {
        let luma = [1, 2, 3, 4, 5, 6];
        let mut grey = Vec::new();
        pack_luma(&mut grey, &luma, 3, 2, 3);
        assert_eq!(grey, luma);
    }

    #[test]
    fn replaces_the_previous_frame() {
        let mut grey = vec![9; 20];
        pack_luma(&mut grey, &[1, 2, 0, 3, 4], 2, 2, 3);
        assert_eq!(grey, [1, 2, 3, 4]);
    }

    #[test]
    fn plane_length_stops_after_the_last_row_pixels() {
        assert_eq!(luma_length(3, 3, 4), 11);
        assert_eq!(luma_length(3, 2, 3), 6);
        assert_eq!(luma_length(3, 0, 4), 0);
    }
}
