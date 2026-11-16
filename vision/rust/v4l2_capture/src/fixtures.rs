//! What the tests of the conversion share.

use crate::bands::Images;
use crate::bayer::{Layout, RawFrame};

/// Marsaglia's xorshift32 from `seed`: the same noise on every run.
pub fn xorshift(seed: u32) -> impl FnMut() -> u32 {
    let mut state = seed;
    move || {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        state
    }
}

/// `rgb` to convert into, without an averaged or NV12 image.
pub fn rgb_only(rgb: &mut Vec<u8>) -> Images<'_> {
    Images {
        rgb,
        averaged: None,
        nv12: None,
    }
}

/// The frame of the rows `raw` holds, each `width` samples stored as
/// `layout` in `row_stride` bytes.
pub fn frame(raw: &[u8], width: usize, row_stride: usize, layout: Layout) -> RawFrame<'_> {
    RawFrame {
        raw,
        width,
        height: raw.len() / row_stride,
        row_stride,
        layout,
    }
}

/// `frame` of packed 12-bit samples.
pub fn packed12_frame(raw: &[u8], width: usize, row_stride: usize) -> RawFrame<'_> {
    frame(raw, width, row_stride, Layout::Packed12)
}
