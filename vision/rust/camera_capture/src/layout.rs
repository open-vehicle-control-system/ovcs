//! The bytes a capture reads of a YUV420 buffer, checked against its mapping
//! before any is read.

use crate::full_range::chroma_size;
use crate::grey::luma_length;

/// The Y, U and V planes' lengths of a `width`×`height` frame, each plane's
/// rows `strides` apart, up to the last row's pixels.
pub fn plane_lengths(width: usize, height: usize, strides: [usize; 3]) -> [usize; 3] {
    let (chroma_width, chroma_height) = chroma_size(width, height);
    [
        luma_length(width, height, strides[0]),
        luma_length(chroma_width, chroma_height, strides[1]),
        luma_length(chroma_width, chroma_height, strides[2]),
    ]
}

/// Whether `length` bytes from `offset` lie within a mapping of `total` bytes.
pub fn holds(total: usize, offset: usize, length: usize) -> bool {
    offset.checked_add(length).is_some_and(|end| end <= total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plane_ends_after_its_last_row_pixels() {
        assert_eq!(plane_lengths(4, 2, [8, 4, 4]), [12, 2, 2]);
    }

    #[test]
    fn odd_sizes_round_the_chroma_rows_up() {
        assert_eq!(plane_lengths(3, 3, [4, 2, 2]), [11, 4, 4]);
    }

    #[test]
    fn packed_planes_take_their_own_strides() {
        assert_eq!(plane_lengths(3, 3, [3, 2, 2]), [9, 4, 4]);
    }

    #[test]
    fn a_mapping_holds_bytes_up_to_its_end_and_no_further() {
        assert!(holds(16, 4, 12));
        assert!(!holds(16, 4, 13));
        assert!(!holds(16, 17, 0));
        assert!(!holds(usize::MAX, usize::MAX, 1));
    }
}
