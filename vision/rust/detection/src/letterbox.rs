//! Letterbox from a caller frame into the model's square NHWC RGB input, and back.

use crate::bilinear;

const PAD_VALUE: u8 = 114;

/// Geometry that maps a caller frame into the model input, kept to invert it on the way out.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Letterbox {
    /// Caller px to model px.
    pub scale: f32,
    /// Left padding, in model px.
    pub offset_x: i32,
    /// Top padding, in model px.
    pub offset_y: i32,
}

/// Fit `width`x`height` into a `model`-sized square, centred.
pub fn letterbox_for(width: i32, height: i32, model: i32) -> Letterbox {
    let scale = (model as f32 / width as f32).min(model as f32 / height as f32);
    let (scaled_width, scaled_height) = scaled_size(width, height, scale);
    Letterbox {
        scale,
        offset_x: (model - scaled_width) / 2,
        offset_y: (model - scaled_height) / 2,
    }
}

fn scaled_size(width: i32, height: i32, scale: f32) -> (i32, i32) {
    (
        (width as f32 * scale).round() as i32,
        (height as f32 * scale).round() as i32,
    )
}

/// A caller frame: `width` × `height` pixels of 1 (grey) or 3 (RGB) channels.
pub struct Frame<'a> {
    pub pixels: &'a [u8],
    pub width: i32,
    pub height: i32,
    pub channels: u8,
}

/// Bilinear resize of `frame` into `destination`, a `model`x`model` RGB buffer padded with
/// 114, YOLO's conventional letterbox fill. The output rows are split into up to `threads`
/// bands, with the same output whatever their count.
pub fn letterbox_into(
    frame: &Frame,
    destination: &mut [u8],
    model: i32,
    letterbox: &Letterbox,
    threads: usize,
) {
    let model_px = model as usize;
    destination[..model_px * model_px * 3].fill(PAD_VALUE);
    match frame.channels {
        1 => resize_into::<1>(frame, destination, model_px, letterbox, threads),
        _ => resize_into::<3>(frame, destination, model_px, letterbox, threads),
    }
}

/// The letterbox's image area, from `frame`'s `CHANNELS`-sample pixels.
fn resize_into<const CHANNELS: usize>(
    frame: &Frame,
    destination: &mut [u8],
    model_px: usize,
    letterbox: &Letterbox,
    threads: usize,
) {
    let (scaled_width, scaled_height) = scaled_size(frame.width, frame.height, letterbox.scale);
    let to_pixels = |samples: f32| samples / letterbox.scale;
    let columns = bilinear::taps(scaled_width as usize, frame.width as usize, to_pixels);
    let rows = bilinear::taps(scaled_height as usize, frame.height as usize, to_pixels);
    let start = (letterbox.offset_y as usize * model_px + letterbox.offset_x as usize) * 3;
    bilinear::resize_into::<CHANNELS>(
        frame.pixels,
        frame.width as usize,
        &columns,
        &rows,
        &mut destination[start..],
        model_px * 3,
        threads,
    );
}

/// Maps `[x0, y0, x1, y1]` in padded model pixels back to caller pixels.
pub fn to_caller(letterbox: &Letterbox, model_box: [f32; 4]) -> [f32; 4] {
    let [x0, y0, x1, y1] = model_box;
    let caller_x = |model_x: f32| (model_x - letterbox.offset_x as f32) / letterbox.scale;
    let caller_y = |model_y: f32| (model_y - letterbox.offset_y as f32) / letterbox.scale;
    [caller_x(x0), caller_y(y0), caller_x(x1), caller_y(y1)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_near(got: [f32; 4], want: [f32; 4]) {
        for (got_coordinate, want_coordinate) in got.iter().zip(want) {
            assert!(
                (got_coordinate - want_coordinate).abs() < 1e-3,
                "{got:?} != {want:?}"
            );
        }
    }

    fn pixel(destination: &[u8], model: i32, x: i32, y: i32) -> [u8; 3] {
        let offset = ((y * model + x) * 3) as usize;
        [
            destination[offset],
            destination[offset + 1],
            destination[offset + 2],
        ]
    }

    #[test]
    fn letterbox_for_480x270_into_640() {
        let letterbox = letterbox_for(480, 270, 640);
        assert_eq!(letterbox.scale, 640.0 / 480.0);
        assert_eq!(letterbox.offset_x, 0);
        assert_eq!(letterbox.offset_y, (640 - 360) / 2);
    }

    #[test]
    fn letterbox_for_portrait_pads_left_and_right() {
        let letterbox = letterbox_for(100, 200, 64);
        assert_eq!(letterbox.scale, 64.0 / 200.0);
        assert_eq!((letterbox.offset_x, letterbox.offset_y), (16, 0));
    }

    #[test]
    fn to_caller_inverts_letterbox() {
        let letterbox = letterbox_for(480, 270, 640);
        assert_near(
            to_caller(&letterbox, [0.0, 140.0, 640.0, 500.0]),
            [0.0, 0.0, 480.0, 270.0],
        );
        assert_near(
            to_caller(&letterbox, [320.0, 320.0, 400.0, 400.0]),
            [240.0, 135.0, 300.0, 195.0],
        );
    }

    #[test]
    fn letterbox_into_pads_with_114() {
        let (width, height, model) = (4, 2, 8);
        let source = vec![200u8; (width * height * 3) as usize];
        let letterbox = letterbox_for(width, height, model);
        assert_eq!((letterbox.offset_x, letterbox.offset_y), (0, 2));
        let mut destination = vec![0u8; (model * model * 3) as usize];
        letterbox_into(
            &Frame {
                pixels: &source,
                width,
                height,
                channels: 3,
            },
            &mut destination,
            model,
            &letterbox,
            1,
        );
        for y in 0..model {
            let want = if (2..6).contains(&y) { 200 } else { 114 };
            for x in 0..model {
                assert_eq!(pixel(&destination, model, x, y), [want; 3], "at {x},{y}");
            }
        }
    }

    #[test]
    fn gray_is_replicated_to_rgb() {
        let source = [10u8, 10, 10, 10];
        let letterbox = letterbox_for(2, 2, 2);
        let mut destination = [0u8; 12];
        letterbox_into(
            &Frame {
                pixels: &source,
                width: 2,
                height: 2,
                channels: 1,
            },
            &mut destination,
            2,
            &letterbox,
            1,
        );
        assert_eq!(destination, [10; 12]);
    }

    #[test]
    fn rgb_is_copied_as_is() {
        let source = [1u8, 2, 3];
        let letterbox = letterbox_for(1, 1, 1);
        let mut destination = [0u8; 3];
        letterbox_into(
            &Frame {
                pixels: &source,
                width: 1,
                height: 1,
                channels: 3,
            },
            &mut destination,
            1,
            &letterbox,
            1,
        );
        assert_eq!(destination, [1, 2, 3]);
    }

    #[test]
    fn bilinear_upscale_samples_pixel_centres() {
        // 2x1 gray [0, 100] upscaled x2: centres at -0.25, 0.25, 0.75, 1.25 source px.
        let source = [0u8, 100];
        let letterbox = letterbox_for(2, 1, 4);
        assert_eq!((letterbox.offset_x, letterbox.offset_y), (0, 1));
        let mut destination = vec![0u8; 4 * 4 * 3];
        letterbox_into(
            &Frame {
                pixels: &source,
                width: 2,
                height: 1,
                channels: 1,
            },
            &mut destination,
            4,
            &letterbox,
            1,
        );
        let row: Vec<u8> = (0..4).map(|x| pixel(&destination, 4, x, 1)[0]).collect();
        assert_eq!(row, [0, 25, 75, 100]);
    }

    /// `length` bytes of a fixed pseudo-random sequence.
    fn noise(length: usize) -> Vec<u8> {
        let mut state = 0x1234_5678u32;
        (0..length)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                (state >> 24) as u8
            })
            .collect()
    }

    /// FNV-1a of `bytes`.
    fn digest(bytes: &[u8]) -> u64 {
        bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, &byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
        })
    }

    #[test]
    fn the_letterboxed_images_keep_their_digests_on_one_to_four_threads() {
        for threads in 1..=4 {
            let digests: Vec<u64> = [
                (1014, 760, 3, 640),
                (1014, 760, 1, 640),
                (37, 23, 3, 64),
                (100, 200, 3, 64),
                (5, 3, 1, 16),
            ]
            .iter()
            .map(|&(width, height, channels, model)| {
                let source = noise((width * height) as usize * usize::from(channels));
                let letterbox = letterbox_for(width, height, model);
                let mut destination = vec![0u8; (model * model * 3) as usize];
                letterbox_into(
                    &Frame {
                        pixels: &source,
                        width,
                        height,
                        channels,
                    },
                    &mut destination,
                    model,
                    &letterbox,
                    threads,
                );
                digest(&destination)
            })
            .collect();
            assert_eq!(
                digests,
                [
                    10712080232157905521,
                    10406381458494913635,
                    7139128084787517588,
                    10434094345790059633,
                    17656103293008597410,
                ],
                "on {threads} threads"
            );
        }
    }
}
