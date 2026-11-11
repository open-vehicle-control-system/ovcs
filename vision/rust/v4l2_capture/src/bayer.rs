//! Raw Bayer to grey or to colour.

use crate::white_balance::Gains;

/// Maps a raw sample to 8 bits: the sensor's black level to 0, full scale
/// to 255, gamma-encoded between them so it displays as the scene.
pub struct Tone {
    table: Vec<u8>,
    black_level: u16,
}

impl Tone {
    /// The tone of 10-bit samples.
    pub fn new(black_level: u16, gamma: f64) -> Tone {
        Tone::with_sample_bits(black_level, gamma, 10)
    }

    /// The tone of `sample_bits`-bit samples, `black_level` in that depth.
    pub fn with_sample_bits(black_level: u16, gamma: f64, sample_bits: u32) -> Tone {
        let full_scale = (1u16 << sample_bits) - 1;
        let range = f64::from(full_scale - black_level.min(full_scale - 1));
        let table = (0..=full_scale)
            .map(|sample| {
                let linear = f64::from(sample.saturating_sub(black_level)) / range;
                (linear.min(1.0).powf(1.0 / gamma) * 255.0).round() as u8
            })
            .collect();
        Tone { table, black_level }
    }

    /// The IMX708's black level, gamma-encoded as sRGB roughly is.
    #[cfg(test)]
    pub fn imx708() -> Tone {
        Tone::new(64, 2.2)
    }

    pub fn grey(&self, sample: u16) -> u8 {
        self.table[usize::from(sample).min(self.table.len() - 1)]
    }

    /// The 8-bit value of `sample` once its signal above the black level is
    /// multiplied by `gain_q12`, a gain in 1/4096ths.
    fn scaled(&self, sample: u16, gain_q12: u32) -> u8 {
        let signal = u32::from(sample.saturating_sub(self.black_level));
        let scaled = u32::from(self.black_level) + ((signal * gain_q12) >> 12);
        self.table[(scaled as usize).min(self.table.len() - 1)]
    }
}

/// How a row's samples are stored.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Layout {
    /// Two little-endian bytes per 10-bit sample (V4L2's `RG10`).
    Unpacked16,
    /// Five bytes per four 10-bit samples: their high 8 bits, then a byte of
    /// their low 2 bits each, the first sample's lowest (V4L2's `pRAA`).
    Packed10,
    /// Three bytes per two 12-bit samples: their high 8 bits, then a byte of
    /// their low 4 bits each, the first sample's lowest (V4L2's `pRCC`).
    Packed12,
}

impl Layout {
    /// The bytes `width` samples take.
    pub fn row_bytes(self, width: usize) -> usize {
        match self {
            Layout::Unpacked16 => width * 2,
            Layout::Packed10 => width * 5 / 4,
            Layout::Packed12 => width * 3 / 2,
        }
    }
}

/// The samples of one row, `out.len()` of them: a multiple of 4 for `Packed10`, of 2 for `Packed12`.
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
        Layout::Packed12 => {
            for (two, bytes) in out.chunks_exact_mut(2).zip(row.chunks_exact(3)) {
                two[0] = (u16::from(bytes[0]) << 4) | u16::from(bytes[2] & 0x0f);
                two[1] = (u16::from(bytes[1]) << 4) | u16::from(bytes[2] >> 4);
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

/// A raw RGGB frame: `height` rows starting every `row_stride` bytes, at
/// least `layout.row_bytes(width)`; `width` and `height` are even.
pub struct RawFrame<'a> {
    pub raw: &'a [u8],
    pub width: usize,
    pub height: usize,
    pub row_stride: usize,
    pub layout: Layout,
}

impl RawFrame<'_> {
    /// Calls `cell_row` with the samples of every `step`-th row of RGGB
    /// cells: its top row's, then its bottom row's.
    fn cell_rows(&self, step: usize, mut cell_row: impl FnMut(&[u16], &[u16])) {
        let row_bytes = self.layout.row_bytes(self.width);
        let (mut top, mut bottom) = (vec![0u16; self.width], vec![0u16; self.width]);
        let rows = &self.raw[..self.row_stride * self.height];
        for pair in rows.chunks_exact(self.row_stride * 2).step_by(step.max(1)) {
            let (top_row, bottom_row) = pair.split_at(self.row_stride);
            samples(&top_row[..row_bytes], self.layout, &mut top);
            samples(&bottom_row[..row_bytes], self.layout, &mut bottom);
            cell_row(&top, &bottom);
        }
    }
}

/// Turns each 2x2 RGGB cell of `frame` into one pixel: red, the mean of both
/// greens, and blue, each through `tone`, red and blue scaled by `gains`
/// first. Halves both dimensions; `rotate_180` turns the image for a sensor
/// mounted upside down. Returns 8-bit red, green and blue per pixel, row-major.
pub fn rgb_half(frame: &RawFrame, tone: &Tone, gains: Gains, rotate_180: bool) -> Vec<u8> {
    let (red_q12, blue_q12) = (q12(gains.red), q12(gains.blue));
    let mut rgb = Vec::with_capacity((frame.width / 2) * (frame.height / 2) * 3);
    frame.cell_rows(1, |top, bottom| {
        for (top_pair, bottom_pair) in top.chunks_exact(2).zip(bottom.chunks_exact(2)) {
            let green = (u32::from(top_pair[1]) + u32::from(bottom_pair[0])) / 2;
            rgb.extend_from_slice(&[
                tone.scaled(top_pair[0], red_q12),
                tone.grey(green as u16),
                tone.scaled(bottom_pair[1], blue_q12),
            ]);
        }
    });
    if rotate_180 {
        // Reversing the bytes reverses the pixels but turns each into blue,
        // green, red; the swap restores red, green, blue.
        rgb.reverse();
        for pixel in rgb.chunks_exact_mut(3) {
            pixel.swap(0, 2);
        }
    }
    rgb
}

fn q12(gain: f64) -> u32 {
    (gain * 4096.0).round() as u32
}

/// The mean red, green and blue above `black_level` over every `row_step`-th
/// row of RGGB cells of `frame`.
pub fn channel_means(frame: &RawFrame, black_level: u16, row_step: usize) -> [f64; 3] {
    let mut sums = [0u64; 3];
    let mut cells = 0u64;
    let signal = |sample: u16| u64::from(sample.saturating_sub(black_level));
    frame.cell_rows(row_step, |top, bottom| {
        for (top_pair, bottom_pair) in top.chunks_exact(2).zip(bottom.chunks_exact(2)) {
            sums[0] += signal(top_pair[0]);
            sums[1] += signal(top_pair[1]) + signal(bottom_pair[0]);
            sums[2] += signal(bottom_pair[1]);
            cells += 1;
        }
    });
    let cells = cells.max(1) as f64;
    [
        sums[0] as f64 / cells,
        sums[1] as f64 / 2.0 / cells,
        sums[2] as f64 / cells,
    ]
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

    #[test]
    fn packed12_rows_take_three_bytes_per_two_samples() {
        assert_eq!(Layout::Packed12.row_bytes(2028), 3042);
        let mut unpacked = [0u16; 4];
        samples(
            &[0xab, 0xcd, 0xef, 0x12, 0x34, 0x56],
            Layout::Packed12,
            &mut unpacked,
        );
        assert_eq!(unpacked, [0xabf, 0xcde, 0x126, 0x345]);
    }

    #[test]
    fn a_12_bit_tone_maps_its_black_level_to_black_and_full_scale_to_white() {
        let tone = Tone::with_sample_bits(256, 2.2, 12);
        assert_eq!(tone.grey(256), 0);
        assert_eq!(tone.grey(200), 0);
        assert_eq!(tone.grey(4095), 255);
        assert_eq!(tone.grey(u16::MAX), 255);
        let mid_grey = tone.grey(256 + (0.18 * 3839.0) as u16);
        assert!((110..=125).contains(&mid_grey), "mid grey {mid_grey}");
    }

    // Two samples to three bytes: their high 8 bits, then their low 4 bits, the first's lowest.
    fn packed12(samples: &[u16]) -> Vec<u8> {
        samples
            .chunks_exact(2)
            .flat_map(|two| {
                [
                    (two[0] >> 4) as u8,
                    (two[1] >> 4) as u8,
                    ((two[0] & 0xf) | ((two[1] & 0xf) << 4)) as u8,
                ]
            })
            .collect()
    }

    fn linear_tone() -> Tone {
        Tone::with_sample_bits(0, 1.0, 12)
    }

    const UNITY: Gains = Gains {
        red: 1.0,
        blue: 1.0,
    };

    // Two RGGB cells side by side: red with a little blue, then blue with some green.
    fn two_cells() -> Vec<u8> {
        packed12(&[4095, 0, 0, 2730, 0, 1365, 2730, 4095])
    }

    #[test]
    fn demosaics_each_rggb_cell_into_one_rgb_pixel() {
        let frame = RawFrame {
            raw: &two_cells(),
            width: 4,
            height: 2,
            row_stride: 6,
            layout: Layout::Packed12,
        };
        assert_eq!(
            rgb_half(&frame, &linear_tone(), UNITY, false),
            [255, 0, 85, 0, 170, 255]
        );
    }

    #[test]
    fn a_rotated_image_keeps_each_pixel_red_green_blue() {
        let frame = RawFrame {
            raw: &two_cells(),
            width: 4,
            height: 2,
            row_stride: 6,
            layout: Layout::Packed12,
        };
        assert_eq!(
            rgb_half(&frame, &linear_tone(), UNITY, true),
            [0, 170, 255, 255, 0, 85]
        );
    }

    #[test]
    fn white_balance_gains_scale_red_and_blue_above_the_black_level() {
        let raw = packed12(&[256 + 400, 256 + 400, 256 + 400, 256 + 400]);
        let frame = RawFrame {
            raw: &raw,
            width: 2,
            height: 2,
            row_stride: 3,
            layout: Layout::Packed12,
        };
        let tone = Tone::with_sample_bits(256, 1.0, 12);
        let gains = Gains {
            red: 2.0,
            blue: 0.5,
        };
        let grey = tone.grey(256 + 400);
        assert_eq!(
            rgb_half(&frame, &tone, gains, false),
            [tone.grey(256 + 800), grey, tone.grey(256 + 200)]
        );
    }

    #[test]
    fn a_gain_saturates_at_full_scale() {
        let raw = packed12(&[4000, 100, 100, 4000]);
        let frame = RawFrame {
            raw: &raw,
            width: 2,
            height: 2,
            row_stride: 3,
            layout: Layout::Packed12,
        };
        let gains = Gains {
            red: 4.0,
            blue: 4.0,
        };
        assert_eq!(rgb_half(&frame, &linear_tone(), gains, false)[0], 255);
    }

    #[test]
    fn channel_means_are_measured_above_the_black_level() {
        let raw = packed12(&[
            256 + 300,
            256 + 100,
            256 + 300,
            256 + 100,
            256 + 300,
            256 + 50,
            256 + 300,
            100,
        ]);
        let frame = RawFrame {
            raw: &raw,
            width: 4,
            height: 2,
            row_stride: 6,
            layout: Layout::Packed12,
        };
        assert_eq!(channel_means(&frame, 256, 1), [300.0, 200.0, 25.0]);
    }
}
