//! The band of an RGB image the model sees, resized to its input.

use std::ops::Range;

/// Bilinear resize of the RGB image's `rows`, `width` pixels wide, into `destination`, an
/// `output_width` × `output_height` RGB image. Samples are taken at pixel centres, and a tap
/// past the band's edge takes the edge's pixel, never a row outside the band.
pub fn resize_band(
    image: &[u8],
    width: usize,
    rows: Range<usize>,
    destination: &mut [u8],
    output_width: usize,
    output_height: usize,
) {
    let columns = taps(width, output_width);
    let image_row = |row: usize| &image[(rows.start + row) * width * 3..][..width * 3];
    let (mut upper, mut lower) = (vec![0f32; output_width * 3], vec![0f32; output_width * 3]);
    let (mut upper_row, mut lower_row) = (None, None);
    for (tap, output_row) in taps(rows.len(), output_height)
        .into_iter()
        .zip(destination.chunks_exact_mut(output_width * 3))
    {
        if upper_row != Some(tap.first) {
            if lower_row == Some(tap.first) {
                std::mem::swap(&mut upper, &mut lower);
                lower_row = upper_row;
            } else {
                blend_row(image_row(tap.first), &columns, &mut upper);
            }
            upper_row = Some(tap.first);
        }
        if lower_row != Some(tap.second) {
            blend_row(image_row(tap.second), &columns, &mut lower);
            lower_row = Some(tap.second);
        }
        let (upper_weight, lower_weight) = (1.0 - tap.weight, tap.weight);
        for ((sample, &upper), &lower) in output_row.iter_mut().zip(&upper).zip(&lower) {
            *sample = (upper * upper_weight + lower * lower_weight).round() as u8;
        }
    }
}

/// The two pixels a sample falls between, clamped to the input, and the second's weight.
#[derive(Clone, Copy)]
struct Tap {
    first: usize,
    second: usize,
    weight: f32,
}

/// For each of `output` samples over `input` pixels, its tap.
fn taps(input: usize, output: usize) -> Vec<Tap> {
    let scale = input as f32 / output as f32;
    let last = input as isize - 1;
    (0..output)
        .map(|sample| {
            let position = (sample as f32 + 0.5) * scale - 0.5;
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

/// The RGB `row` blended between each column tap's two pixels into `blended`.
fn blend_row(row: &[u8], columns: &[Tap], blended: &mut [f32]) {
    for (tap, samples) in columns.iter().zip(blended.chunks_exact_mut(3)) {
        let (first_weight, second_weight) = (1.0 - tap.weight, tap.weight);
        let first = &row[tap.first * 3..][..3];
        let second = &row[tap.second * 3..][..3];
        for channel in 0..3 {
            samples[channel] = f32::from(first[channel]) * first_weight
                + f32::from(second[channel]) * second_weight;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An RGB image whose pixel at (x, y) is `pixel(x, y)`.
    fn image(width: usize, height: usize, pixel: impl Fn(usize, usize) -> [u8; 3]) -> Vec<u8> {
        (0..height)
            .flat_map(|y| (0..width).map(move |x| (x, y)))
            .flat_map(|(x, y)| pixel(x, y))
            .collect()
    }

    fn resized(source: &[u8], width: usize, rows: Range<usize>, output: (usize, usize)) -> Vec<u8> {
        let mut destination = vec![0; output.0 * output.1 * 3];
        resize_band(source, width, rows, &mut destination, output.0, output.1);
        destination
    }

    #[test]
    fn a_band_of_the_input_size_is_copied_in_rgb_order() {
        let source = image(3, 4, |x, y| [x as u8, y as u8, 100 + (x + 3 * y) as u8]);
        let band = image(3, 2, |x, y| {
            [x as u8, (y + 1) as u8, 100 + (x + 3 * (y + 1)) as u8]
        });
        assert_eq!(resized(&source, 3, 1..3, (3, 2)), band);
    }

    #[test]
    fn halving_the_band_averages_each_two_by_two_block() {
        let source = image(4, 2, |x, y| {
            [(10 * x + 40 * y) as u8, 8, 200 - (x + y) as u8]
        });
        assert_eq!(resized(&source, 4, 0..2, (2, 1)), [25, 8, 199, 45, 8, 197]);
    }

    #[test]
    fn the_rows_outside_the_band_never_leak_in() {
        let source = image(2, 4, |_, y| match y {
            1 => [10; 3],
            2 => [30; 3],
            _ => [255; 3],
        });
        let rows: Vec<u8> = resized(&source, 2, 1..3, (2, 4))
            .chunks_exact(6)
            .map(|row| row[0])
            .collect();
        assert_eq!(rows, [10, 15, 25, 30]);
    }

    #[test]
    fn width_and_height_scale_on_their_own() {
        let source = image(4, 2, |x, y| [(20 * x) as u8, (100 * y) as u8, 0]);
        assert_eq!(
            resized(&source, 4, 0..2, (2, 2)),
            [10, 0, 0, 50, 0, 0, 10, 100, 0, 50, 100, 0]
        );
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
    fn the_resized_bands_keep_their_digests() {
        let digests: Vec<u64> = [
            (1014, 760, 126..633, (1024, 512)),
            (1014, 760, 0..760, (256, 128)),
            (13, 9, 2..7, (40, 17)),
            (7, 5, 4..5, (3, 2)),
        ]
        .into_iter()
        .map(|(width, height, rows, output)| {
            digest(&resized(&noise(width * height * 3), width, rows, output))
        })
        .collect();
        assert_eq!(
            digests,
            [
                7170474687542579749,
                12029912228537717427,
                16906896625238522488,
                13368472135222443375,
            ]
        );
    }
}
