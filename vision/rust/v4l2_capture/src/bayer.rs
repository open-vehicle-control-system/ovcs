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

/// Averages each 2x2 RGGB cell of 10-bit little-endian samples into one grey
/// pixel through `tone`, halving both dimensions; `rotate_180` turns the image
/// for a sensor mounted upside down.
pub fn grey_half(
    raw: &[u8],
    width: usize,
    height: usize,
    tone: &Tone,
    rotate_180: bool,
) -> Vec<u8> {
    let row_bytes = width * 2;
    let mut grey = Vec::with_capacity((width / 2) * (height / 2));
    for rows in raw[..row_bytes * height].chunks_exact(row_bytes * 2) {
        let (top, bottom) = rows.split_at(row_bytes);
        for (top_pair, bottom_pair) in top.chunks_exact(4).zip(bottom.chunks_exact(4)) {
            let sum = u32::from(u16::from_le_bytes([top_pair[0], top_pair[1]]))
                + u32::from(u16::from_le_bytes([top_pair[2], top_pair[3]]))
                + u32::from(u16::from_le_bytes([bottom_pair[0], bottom_pair[1]]))
                + u32::from(u16::from_le_bytes([bottom_pair[2], bottom_pair[3]]));
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
        assert_eq!(grey_half(&raw, 4, 2, &Tone::new(0, 1.0), false), [255, 150]);
    }

    #[test]
    fn black_stays_black() {
        assert_eq!(
            grey_half(
                &little_endian_samples(&[0, 0, 0, 0]),
                2,
                2,
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
        assert_eq!(grey_half(&raw, 8, 2, &tone, false), [0, 0, 255, 255]);
        assert_eq!(grey_half(&raw, 8, 2, &tone, true), [255, 255, 0, 0]);
    }
}
