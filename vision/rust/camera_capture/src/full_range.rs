//! Full-range YUV for the JPEG encoder. A JFIF JPEG holds full-range YCbCr,
//! 0 to 255, while a limited-range stream's luma spans 16 to 235 and its
//! chroma 16 to 240.

/// The quantisation range of a stream's YUV, as libcamera reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Range {
    Full,
    Limited,
}

/// Whether a stream's frames are expanded before the JPEG encode. A stream
/// with no colour space reported is encoded as captured.
pub fn expands(range: Option<Range>) -> bool {
    range == Some(Range::Limited)
}

/// Limited range's luma black and span.
const LUMA_FLOOR: f64 = 16.0;
const LUMA_SPAN: f64 = 219.0;
/// Limited range's chroma span around its neutral 128.
const CHROMA_SPAN: f64 = 224.0;
const CHROMA_NEUTRAL: f64 = 128.0;

fn table(expand: impl Fn(f64) -> f64) -> [u8; 256] {
    std::array::from_fn(|value| expand(value as f64).round().clamp(0.0, 255.0) as u8)
}

/// A frame's YUV420 planes expanded from limited to full range, into buffers
/// reused from frame to frame.
pub struct Expansion {
    luma: [u8; 256],
    chroma: [u8; 256],
    planes: [Vec<u8>; 3],
}

impl Default for Expansion {
    fn default() -> Self {
        Expansion {
            luma: table(|luma| (luma - LUMA_FLOOR) * 255.0 / LUMA_SPAN),
            // Rounded away from 128 on both sides, so 16 and 240 land on 0 and 255.
            chroma: table(|chroma| {
                CHROMA_NEUTRAL + ((chroma - CHROMA_NEUTRAL) * 255.0 / CHROMA_SPAN).round()
            }),
            planes: Default::default(),
        }
    }
}

impl Expansion {
    /// Expands the Y, U and V `planes` of a `width`×`height` frame, each plane's
    /// rows `strides` apart. The expanded planes are packed: their strides are
    /// their widths.
    pub fn expand(
        &mut self,
        planes: [&[u8]; 3],
        strides: [usize; 3],
        width: usize,
        height: usize,
    ) -> [&[u8]; 3] {
        let (chroma_width, chroma_height) = chroma_size(width, height);
        let [y, u, v] = &mut self.planes;
        map_plane(&self.luma, y, planes[0], width, height, strides[0]);
        map_plane(
            &self.chroma,
            u,
            planes[1],
            chroma_width,
            chroma_height,
            strides[1],
        );
        map_plane(
            &self.chroma,
            v,
            planes[2],
            chroma_width,
            chroma_height,
            strides[2],
        );
        [&self.planes[0], &self.planes[1], &self.planes[2]]
    }
}

/// The size of a YUV420 frame's U and V planes.
pub fn chroma_size(width: usize, height: usize) -> (usize, usize) {
    (width.div_ceil(2), height.div_ceil(2))
}

/// The first `width` bytes of each of `height` rows `stride` apart, through `table`, into `out`.
fn map_plane(
    table: &[u8; 256],
    out: &mut Vec<u8>,
    plane: &[u8],
    width: usize,
    height: usize,
    stride: usize,
) {
    out.clear();
    for row in plane.chunks(stride).take(height) {
        out.extend(row[..width].iter().map(|&value| table[usize::from(value)]));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn expand_flat(luma: u8, chroma: u8) -> (u8, u8) {
        let mut expansion = Expansion::default();
        let [y, u, _] = expansion.expand([&[luma; 4], &[chroma], &[chroma]], [2, 1, 1], 2, 2);
        (y[0], u[0])
    }

    #[test]
    fn only_a_limited_range_stream_is_expanded() {
        assert!(expands(Some(Range::Limited)));
        assert!(!expands(Some(Range::Full)));
        assert!(!expands(None));
    }

    #[test]
    fn limited_luma_spans_the_full_range() {
        assert_eq!(expand_flat(16, 128).0, 0);
        assert_eq!(expand_flat(235, 128).0, 255);
        assert_eq!(expand_flat(126, 128).0, 128);
    }

    #[test]
    fn luma_outside_the_limited_range_is_clamped() {
        assert_eq!(expand_flat(0, 128).0, 0);
        assert_eq!(expand_flat(15, 128).0, 0);
        assert_eq!(expand_flat(236, 128).0, 255);
        assert_eq!(expand_flat(255, 128).0, 255);
    }

    #[test]
    fn limited_chroma_spans_the_full_range_and_stays_neutral_at_128() {
        assert_eq!(expand_flat(128, 16).1, 0);
        assert_eq!(expand_flat(128, 240).1, 255);
        assert_eq!(expand_flat(128, 128).1, 128);
        assert_eq!(expand_flat(128, 0).1, 0);
        assert_eq!(expand_flat(128, 255).1, 255);
    }

    #[test]
    fn expansion_never_reverses_an_order() {
        let expansion = Expansion::default();
        for table in [&expansion.luma, &expansion.chroma] {
            assert!(table.windows(2).all(|pair| pair[0] <= pair[1]));
        }
    }

    #[test]
    fn expanded_planes_drop_the_padding_after_each_row() {
        let mut expansion = Expansion::default();
        let y = [16, 235, 0xee, 0xee, 235, 16, 0xee, 0xee];
        let u = [16, 0xee];
        let v = [240, 0xee];
        let planes = expansion.expand([&y, &u, &v], [4, 2, 2], 2, 2);
        assert_eq!(planes, [&[0, 255, 255, 0][..], &[0], &[255]]);
    }

    #[test]
    fn odd_sizes_round_the_chroma_planes_up() {
        let mut expansion = Expansion::default();
        let y = [16; 9];
        let chroma = [128; 4];
        let [y, u, v] = expansion.expand([&y, &chroma, &chroma], [3, 2, 2], 3, 3);
        assert_eq!((y.len(), u.len(), v.len()), (9, 4, 4));
    }

    #[test]
    fn a_frame_replaces_the_previous_one() {
        let mut expansion = Expansion::default();
        expansion.expand([&[235; 16], &[240; 4], &[240; 4]], [4, 2, 2], 4, 4);
        let planes = expansion.expand([&[16; 4], &[16], &[16]], [2, 1, 1], 2, 2);
        assert_eq!(planes, [&[0; 4][..], &[0], &[0]]);
    }
}
