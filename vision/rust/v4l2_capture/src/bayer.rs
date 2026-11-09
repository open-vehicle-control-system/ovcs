//! Raw Bayer to grey.

/// Maps a 10-bit sample to 8-bit grey: the sensor's black level to 0, full
/// scale to 255, gamma-encoded between them so it displays as the scene.
pub struct Tone {
    table: Vec<u8>,
}

impl Tone {
    pub fn new(black_level: u16, gamma: f64) -> Tone {
        let range = f64::from(1023 - black_level.min(1022));
        let table = (0..1024u16)
            .map(|sample| {
                let linear = f64::from(sample.saturating_sub(black_level)) / range;
                (linear.min(1.0).powf(1.0 / gamma) * 255.0).round() as u8
            })
            .collect();
        Tone { table }
    }

    /// The IMX708's black level, gamma-encoded as sRGB roughly is.
    #[cfg(test)]
    pub fn imx708() -> Tone {
        Tone::new(64, 2.2)
    }

    pub fn grey(&self, sample: u16) -> u8 {
        self.table[usize::from(sample.min(1023))]
    }
}

/// How a row's 10-bit samples are stored.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Layout {
    /// Two little-endian bytes per sample (V4L2's `RG10`).
    Unpacked16,
    /// Five bytes per four samples: their high 8 bits, then a byte of their
    /// low 2 bits each, the first sample's lowest (V4L2's `pRAA`).
    Packed10,
}

impl Layout {
    /// The bytes `width` samples take.
    pub fn row_bytes(self, width: usize) -> usize {
        match self {
            Layout::Unpacked16 => width * 2,
            Layout::Packed10 => width * 5 / 4,
        }
    }
}

/// The 10-bit samples of one row, `out.len()` of them, a multiple of 4.
fn samples(row: &[u8], layout: Layout, out: &mut [u16]) {
    match layout {
        Layout::Unpacked16 => {
            for (sample, bytes) in out.iter_mut().zip(row.chunks_exact(2)) {
                *sample = u16::from_le_bytes([bytes[0], bytes[1]]);
            }
        }
        Layout::Packed10 => {
            for (four, bytes) in out.chunks_exact_mut(4).zip(row.chunks_exact(5)) {
                for (i, sample) in four.iter_mut().enumerate() {
                    *sample = (u16::from(bytes[i]) << 2) | u16::from((bytes[4] >> (2 * i)) & 3);
                }
            }
        }
    }
}

/// Averages each 2x2 RGGB cell of 10-bit samples stored as `layout` into one
/// grey pixel through `tone`, halving both dimensions; `rotate_180` turns the
/// image for a sensor mounted upside down. Rows start every `row_stride`
/// bytes, at least `layout.row_bytes(width)`, and `raw` holds `height` of them.
pub fn grey_half(
    raw: &[u8],
    width: usize,
    height: usize,
    row_stride: usize,
    layout: Layout,
    tone: &Tone,
    rotate_180: bool,
) -> Vec<u8> {
    let row_bytes = layout.row_bytes(width);
    let mut grey = Vec::with_capacity((width / 2) * (height / 2));
    let (mut top_samples, mut bottom_samples) = (vec![0u16; width], vec![0u16; width]);
    for rows in raw[..row_stride * height].chunks_exact(row_stride * 2) {
        let (top, bottom) = rows.split_at(row_stride);
        samples(&top[..row_bytes], layout, &mut top_samples);
        samples(&bottom[..row_bytes], layout, &mut bottom_samples);
        for (top_pair, bottom_pair) in top_samples
            .chunks_exact(2)
            .zip(bottom_samples.chunks_exact(2))
        {
            let sum = u32::from(top_pair[0])
                + u32::from(top_pair[1])
                + u32::from(bottom_pair[0])
                + u32::from(bottom_pair[1]);
            grey.push(tone.grey((sum / 4) as u16));
        }
    }
    // Row-major order reversed: the image turned by 180 degrees.
    if rotate_180 {
        grey.reverse();
    }
    grey
}

#[cfg(test)]
mod tests {
    use super::*;

    fn little_endian_samples(samples: &[u16]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    #[test]
    fn averages_each_rggb_cell_into_one_grey_byte() {
        let raw = little_endian_samples(&[1023, 1023, 400, 800, 1023, 1023, 800, 400]);
        assert_eq!(
            grey_half(&raw, 4, 2, 8, Layout::Unpacked16, &Tone::new(0, 1.0), false),
            [255, 150]
        );
    }

    #[test]
    fn black_stays_black() {
        assert_eq!(
            grey_half(
                &little_endian_samples(&[0, 0, 0, 0]),
                2,
                2,
                4,
                Layout::Unpacked16,
                &Tone::imx708(),
                false
            ),
            [0]
        );
    }

    #[test]
    fn the_black_level_is_black_and_mid_grey_is_gamma_encoded() {
        let tone = Tone::imx708();
        assert_eq!(tone.grey(64), 0);
        assert_eq!(tone.grey(1023), 255);
        // 18 % of the sensor's range above black: mid grey on a display.
        let mid_grey = tone.grey(64 + (0.18 * 959.0) as u16);
        assert!((110..=125).contains(&mid_grey), "mid grey {mid_grey}");
    }

    #[test]
    fn tone_mapped_conversion_and_rotation() {
        let tone = Tone::imx708();
        let raw = little_endian_samples(&[
            64, 64, 64, 64, 1023, 1023, 1023, 1023, 64, 64, 64, 64, 1023, 1023, 1023, 1023,
        ]);
        assert_eq!(
            grey_half(&raw, 8, 2, 16, Layout::Unpacked16, &tone, false),
            [0, 0, 255, 255]
        );
        assert_eq!(
            grey_half(&raw, 8, 2, 16, Layout::Unpacked16, &tone, true),
            [255, 255, 0, 0]
        );
    }

    // Four samples to five bytes: their high 8 bits, then their low 2 bits each.
    fn packed10(samples: &[u16]) -> Vec<u8> {
        samples
            .chunks_exact(4)
            .flat_map(|four| {
                let mut bytes: Vec<u8> = four.iter().map(|s| (s >> 2) as u8).collect();
                bytes.push(
                    four.iter()
                        .enumerate()
                        .fold(0u8, |low, (i, s)| low | (((s & 3) as u8) << (2 * i))),
                );
                bytes
            })
            .collect()
    }

    #[test]
    fn packed_and_unpacked_rows_give_the_same_grey() {
        let samples = [1023, 513, 402, 801, 1022, 1021, 803, 399];
        let tone = Tone::new(0, 1.0);
        let unpacked = little_endian_samples(&samples);
        let packed = packed10(&samples);
        assert_eq!(
            grey_half(&packed, 4, 2, 5, Layout::Packed10, &tone, false),
            grey_half(&unpacked, 4, 2, 8, Layout::Unpacked16, &tone, false)
        );
    }

    #[test]
    fn padding_at_the_end_of_each_row_is_skipped() {
        let tone = Tone::new(0, 1.0);
        let packed = little_endian_samples(&[1023, 1023, 400, 800, 1023, 1023, 800, 400]);
        let padded: Vec<u8> = packed
            .chunks_exact(8)
            .flat_map(|row| [row, &[0xff; 8][..]].concat())
            .collect();
        assert_eq!(
            grey_half(&padded, 4, 2, 16, Layout::Unpacked16, &tone, false),
            grey_half(&packed, 4, 2, 8, Layout::Unpacked16, &tone, false)
        );
    }
}
