//! Letterbox from a caller frame into the model's square NHWC RGB input, and back.

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

/// Bilinear resize of `source` (gray or RGB) into `destination`, a `model`x`model` RGB buffer
/// padded with 114, YOLO's conventional letterbox fill.
pub fn letterbox_into(
    source: &[u8],
    width: i32,
    height: i32,
    channels: u8,
    destination: &mut [u8],
    model: i32,
    letterbox: &Letterbox,
) {
    let model_px = model as usize;
    destination[..model_px * model_px * 3].fill(PAD_VALUE);
    match channels {
        1 => resize_into::<1>(source, width, height, destination, model_px, letterbox),
        _ => resize_into::<3>(source, width, height, destination, model_px, letterbox),
    }
}

/// The two source pixels a sample falls between, clamped to the image, and the second's
/// weight, sampled at pixel centres so the image does not creep half a pixel up-left.
#[derive(Clone, Copy)]
struct Tap {
    first: usize,
    second: usize,
    weight: f32,
}

/// The taps of `samples` samples over `pixels` pixels, at `scale` samples a pixel.
fn taps(samples: i32, pixels: i32, scale: f32) -> Vec<Tap> {
    (0..samples)
        .map(|sample| {
            let position = (sample as f32 + 0.5) / scale - 0.5;
            let first = position.floor() as i32;
            Tap {
                first: first.max(0).min(pixels - 1) as usize,
                second: (first + 1).max(0).min(pixels - 1) as usize,
                weight: position - first as f32,
            }
        })
        .collect()
}

/// The letterbox's image area, each sample blended along its row first, then between its
/// two rows; a row blended for one output row is kept for the next.
fn resize_into<const CHANNELS: usize>(
    source: &[u8],
    width: i32,
    height: i32,
    destination: &mut [u8],
    model_px: usize,
    letterbox: &Letterbox,
) {
    let (scaled_width, scaled_height) = scaled_size(width, height, letterbox.scale);
    let columns = taps(scaled_width, width, letterbox.scale);
    let source_row = |row: usize| {
        let start = row * width as usize * CHANNELS;
        &source[start..start + width as usize * CHANNELS]
    };
    let blended_length = columns.len() * CHANNELS;
    let (mut upper, mut lower) = (vec![0f32; blended_length], vec![0f32; blended_length]);
    let (mut upper_row, mut lower_row) = (None, None);

    for (y, tap) in taps(scaled_height, height, letterbox.scale)
        .into_iter()
        .enumerate()
    {
        if upper_row != Some(tap.first) {
            if lower_row == Some(tap.first) {
                std::mem::swap(&mut upper, &mut lower);
                lower_row = upper_row;
            } else {
                blend_row::<CHANNELS>(source_row(tap.first), &columns, &mut upper);
            }
            upper_row = Some(tap.first);
        }
        if lower_row != Some(tap.second) {
            blend_row::<CHANNELS>(source_row(tap.second), &columns, &mut lower);
            lower_row = Some(tap.second);
        }

        let start =
            ((letterbox.offset_y + y as i32) as usize * model_px + letterbox.offset_x as usize) * 3;
        let row = &mut destination[start..start + columns.len() * 3];
        let (upper_weight, lower_weight) = (1.0 - tap.weight, tap.weight);
        let blend =
            |upper: f32, lower: f32| (upper * upper_weight + lower * lower_weight).round() as u8;
        if CHANNELS == 3 {
            for ((sample, &upper), &lower) in row.iter_mut().zip(&upper).zip(&lower) {
                *sample = blend(upper, lower);
            }
        } else {
            for ((pixel, &upper), &lower) in row.chunks_exact_mut(3).zip(&upper).zip(&lower) {
                pixel.fill(blend(upper, lower));
            }
        }
    }
}

/// `row` blended between each column tap's two pixels into `blended`, channel by channel.
fn blend_row<const CHANNELS: usize>(row: &[u8], columns: &[Tap], blended: &mut [f32]) {
    for (tap, samples) in columns.iter().zip(blended.chunks_exact_mut(CHANNELS)) {
        let (first_weight, second_weight) = (1.0 - tap.weight, tap.weight);
        let first = &row[tap.first * CHANNELS..][..CHANNELS];
        let second = &row[tap.second * CHANNELS..][..CHANNELS];
        for channel in 0..CHANNELS {
            samples[channel] = f32::from(first[channel]) * first_weight
                + f32::from(second[channel]) * second_weight;
        }
    }
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
            &source,
            width,
            height,
            3,
            &mut destination,
            model,
            &letterbox,
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
        letterbox_into(&source, 2, 2, 1, &mut destination, 2, &letterbox);
        assert_eq!(destination, [10; 12]);
    }

    #[test]
    fn rgb_is_copied_as_is() {
        let source = [1u8, 2, 3];
        let letterbox = letterbox_for(1, 1, 1);
        let mut destination = [0u8; 3];
        letterbox_into(&source, 1, 1, 3, &mut destination, 1, &letterbox);
        assert_eq!(destination, [1, 2, 3]);
    }

    #[test]
    fn bilinear_upscale_samples_pixel_centres() {
        // 2x1 gray [0, 100] upscaled x2: centres at -0.25, 0.25, 0.75, 1.25 source px.
        let source = [0u8, 100];
        let letterbox = letterbox_for(2, 1, 4);
        assert_eq!((letterbox.offset_x, letterbox.offset_y), (0, 1));
        let mut destination = vec![0u8; 4 * 4 * 3];
        letterbox_into(&source, 2, 1, 1, &mut destination, 4, &letterbox);
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
    fn the_letterboxed_images_keep_their_digests() {
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
                &source,
                width,
                height,
                channels,
                &mut destination,
                model,
                &letterbox,
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
            ]
        );
    }
}
