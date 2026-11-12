//! Bilinear resize sampled at pixel centres, each output row blended along its source rows
//! first, then between them.

/// The two source pixels a sample falls between, clamped to the image, and the second's
/// weight.
#[derive(Clone, Copy)]
pub struct Tap {
    first: usize,
    second: usize,
    weight: f32,
}

/// The taps of `samples` samples over `pixels` pixels, `to_pixels` mapping a distance in
/// samples to one in pixels. Samples and pixels are taken at their centres, so the image does
/// not creep half a pixel up-left.
pub fn taps(samples: usize, pixels: usize, to_pixels: impl Fn(f32) -> f32) -> Vec<Tap> {
    let last = pixels as isize - 1;
    (0..samples)
        .map(|sample| {
            let position = to_pixels(sample as f32 + 0.5) - 0.5;
            let first = position.floor();
            let weight = position - first;
            let first = first as isize;
            Tap {
                first: first.clamp(0, last) as usize,
                second: (first + 1).clamp(0, last) as usize,
                weight,
            }
        })
        .collect()
}

/// Resizes `source`, `CHANNELS` (1 or 3) samples a pixel and `source_width` pixels a row,
/// along `columns` and `rows` into RGB rows of `destination`, `stride` bytes apart from its
/// start; grey is replicated to RGB. A source row blended for one output row is kept for the
/// next.
pub fn resize_into<const CHANNELS: usize>(
    source: &[u8],
    source_width: usize,
    columns: &[Tap],
    rows: &[Tap],
    destination: &mut [u8],
    stride: usize,
) {
    let source_row =
        |row: usize| &source[row * source_width * CHANNELS..][..source_width * CHANNELS];
    let blended_length = columns.len() * CHANNELS;
    let (mut upper, mut lower) = (vec![0f32; blended_length], vec![0f32; blended_length]);
    let (mut upper_row, mut lower_row) = (None, None);

    for (y, tap) in rows.iter().enumerate() {
        if upper_row != Some(tap.first) {
            if lower_row == Some(tap.first) {
                std::mem::swap(&mut upper, &mut lower);
                lower_row = upper_row;
            } else {
                blend_row::<CHANNELS>(source_row(tap.first), columns, &mut upper);
            }
            upper_row = Some(tap.first);
        }
        if lower_row != Some(tap.second) {
            blend_row::<CHANNELS>(source_row(tap.second), columns, &mut lower);
            lower_row = Some(tap.second);
        }

        let row = &mut destination[y * stride..][..columns.len() * 3];
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
