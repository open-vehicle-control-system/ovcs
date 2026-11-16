//! The chroma denoise of the colour path.

use std::ops::Range;

/// Rec. 709's luma weights of linear red, green and blue, in 1/1024ths.
const LUMA: [i32; 3] = [218, 732, 74];
const LUMA_SHIFT: u32 = 10;

/// Blurs the chroma of rows of pixels' linear red, green and blue and keeps
/// each pixel's luma. The chroma, red less green and blue less green, is
/// averaged over cells of `cell_size` by `cell_size` pixels, then blurred over cells
/// by 1-4-6-4-1 across and down, the edge cells standing in for those
/// beyond; each pixel then takes its cell's chroma around its own luma.
/// Cb and Cr are linear in red and blue less green once luma is kept, so
/// they blur alike.
#[derive(Default)]
pub(super) struct ChromaDenoise {
    width: usize,
    cell_size: usize,
    cell_rows: usize,
    /// The next cell row to hand out, and the one after the last.
    next: usize,
    end: usize,
    /// Each pixel's luma in 1/1024ths, for the pixel rows of the last three
    /// cell rows, at index cell row % 3.
    luma: [Vec<i32>; 3],
    /// The chroma summed over each cell of the cell row coming in.
    sums: [Vec<i32>; 2],
    /// A cell row's chroma, with two cells beyond each end.
    padded: Vec<i32>,
    /// The last five cell rows' chroma blurred across, in 1/16ths, at index
    /// cell row % 5.
    across: [[Vec<i32>; 5]; 2],
    /// A cell row's chroma blurred both ways.
    blurred: [Vec<i32>; 2],
    /// A row of pixels with that chroma.
    out: Vec<i32>,
}

impl ChromaDenoise {
    /// Starts the cell rows `band` of an image of `cell_rows` rows of
    /// cells of `cell_size` by `cell_size` pixels, 1 or 2, `width` pixels wide.
    /// Returns the rows of pixels to push: those of `band` and of the two
    /// cell rows on each side of it within the image, the blur's reach.
    pub(super) fn start(
        &mut self,
        width: usize,
        cell_size: usize,
        cell_rows: usize,
        band: Range<usize>,
    ) -> Range<usize> {
        let cells = width / cell_size;
        (self.width, self.cell_size, self.cell_rows) = (width, cell_size, cell_rows);
        (self.next, self.end) = (band.start, band.end.min(cell_rows));
        for luma in &mut self.luma {
            luma.resize(cell_size * width, 0);
        }
        self.padded.resize(cells + 4, 0);
        for row in self
            .sums
            .iter_mut()
            .chain(self.across.iter_mut().flatten())
            .chain(&mut self.blurred)
        {
            row.resize(cells, 0);
        }
        self.out.resize(width * 3, 0);
        cell_size * self.next.saturating_sub(2)..cell_size * (self.end + 2).min(cell_rows)
    }

    /// Takes row `y` of pixels, and hands each row of pixels of the band
    /// whose cell row's chroma is blurred, two cell rows behind, to
    /// `denoised(y, rgb)`.
    pub(super) fn push(&mut self, y: usize, rgb: &[i32], mut denoised: impl FnMut(usize, &[i32])) {
        let (cell_row, row_in_cell) = (y / self.cell_size, y % self.cell_size);
        let width = self.width;
        let luma = &mut self.luma[cell_row % 3][row_in_cell * width..(row_in_cell + 1) * width];
        for (pixel, luma) in rgb.chunks_exact(3).zip(luma) {
            *luma = LUMA[0] * pixel[0] + LUMA[1] * pixel[1] + LUMA[2] * pixel[2];
        }
        if row_in_cell == 0 {
            for sums in &mut self.sums {
                sums.fill(0);
            }
        }
        if self.cell_size == 2 {
            add_chroma::<2>(rgb, &mut self.sums);
        } else {
            add_chroma::<1>(rgb, &mut self.sums);
        }
        if row_in_cell + 1 == self.cell_size {
            self.blur_across(cell_row);
            if self.next < self.end && cell_row >= self.next + 2 {
                self.hand_out(&mut denoised);
            }
        }
    }

    /// Hands the band's rows still held to `denoised(y, rgb)`.
    pub(super) fn finish(&mut self, mut denoised: impl FnMut(usize, &[i32])) {
        while self.next < self.end {
            self.hand_out(&mut denoised);
        }
    }

    /// Averages the chroma of cell row `cell_row` over its cells and blurs
    /// it across.
    fn blur_across(&mut self, cell_row: usize) {
        let shift = 2 * self.cell_size.trailing_zeros();
        let half = (1 << shift) >> 1;
        let ChromaDenoise {
            sums,
            padded,
            across,
            ..
        } = self;
        let cells = padded.len() - 4;
        for (sums, across) in sums.iter().zip(across.iter_mut()) {
            for (padded, &sum) in padded[2..cells + 2].iter_mut().zip(sums) {
                *padded = (sum + half) >> shift;
            }
            (padded[0], padded[1]) = (padded[2], padded[2]);
            (padded[cells + 2], padded[cells + 3]) = (padded[cells + 1], padded[cells + 1]);
            for (blurred, window) in across[cell_row % 5].iter_mut().zip(padded.windows(5)) {
                *blurred = window[0] + window[4] + 4 * (window[1] + window[3]) + 6 * window[2];
            }
        }
    }

    /// Blurs the next cell row's chroma down, and hands each of its rows of
    /// pixels, each pixel with that chroma and its own luma, to
    /// `denoised(y, rgb)`.
    fn hand_out(&mut self, denoised: &mut impl FnMut(usize, &[i32])) {
        let cell_row = self.next;
        self.next += 1;
        let last = self.cell_rows - 1;
        let rows: [usize; 5] =
            std::array::from_fn(|offset| (cell_row + offset).saturating_sub(2).min(last) % 5);
        let ChromaDenoise {
            width,
            cell_size,
            luma,
            across,
            blurred,
            out,
            ..
        } = self;
        for (across, blurred) in across.iter().zip(blurred.iter_mut()) {
            let [up2, up1, centre, down1, down2] = rows.map(|row| &across[row][..]);
            for (((((blurred, &up2), &up1), &centre), &down1), &down2) in blurred
                .iter_mut()
                .zip(up2)
                .zip(up1)
                .zip(centre)
                .zip(down1)
                .zip(down2)
            {
                *blurred = (up2 + down2 + 4 * (up1 + down1) + 6 * centre + 128) >> 8;
            }
        }
        for row_in_cell in 0..*cell_size {
            let luma = &luma[cell_row % 3][row_in_cell * *width..(row_in_cell + 1) * *width];
            if *cell_size == 2 {
                rebuild::<2>(luma, blurred, out);
            } else {
                rebuild::<1>(luma, blurred, out);
            }
            denoised(cell_row * *cell_size + row_in_cell, out);
        }
    }
}

/// Adds the chroma of each cell of `CELL_SIZE` pixels of `rgb` to `sums`.
fn add_chroma<const CELL_SIZE: usize>(rgb: &[i32], [red_sums, blue_sums]: &mut [Vec<i32>; 2]) {
    for ((cell, red), blue) in rgb
        .chunks_exact(3 * CELL_SIZE)
        .zip(red_sums.iter_mut())
        .zip(blue_sums.iter_mut())
    {
        for pixel in cell.chunks_exact(3) {
            *red += pixel[0] - pixel[1];
            *blue += pixel[2] - pixel[1];
        }
    }
}

/// Writes to `out` each pixel of cells of `CELL_SIZE` pixels with its cell's
/// `chroma` around its own `luma`.
fn rebuild<const CELL_SIZE: usize>(luma: &[i32], [red, blue]: &[Vec<i32>; 2], out: &mut [i32]) {
    let half = 1 << (LUMA_SHIFT - 1);
    for (((pixels, lumas), &red), &blue) in out
        .chunks_exact_mut(3 * CELL_SIZE)
        .zip(luma.chunks_exact(CELL_SIZE))
        .zip(red)
        .zip(blue)
    {
        for (pixel, &luma) in pixels.chunks_exact_mut(3).zip(lumas) {
            let green = (luma - LUMA[0] * red - LUMA[2] * blue + half) >> LUMA_SHIFT;
            pixel[0] = green + red;
            pixel[1] = green;
            pixel[2] = green + blue;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Noise uniform within -amplitude..=amplitude.
    fn noise(amplitude: i32, seed: u32) -> impl FnMut() -> i32 {
        let mut state = seed;
        move || {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            (state % (2 * amplitude as u32 + 1)) as i32 - amplitude
        }
    }

    // `rows` of linear red, green and blue through the chroma denoise at
    // cells of `cell_size` by `cell_size` pixels.
    fn denoised(rows: &[Vec<i32>], cell_size: usize) -> Vec<Vec<i32>> {
        let mut denoise = ChromaDenoise::default();
        let cell_rows = rows.len() / cell_size;
        denoise.start(rows[0].len() / 3, cell_size, cell_rows, 0..cell_rows);
        let mut out = vec![Vec::new(); rows.len()];
        for (y, row) in rows.iter().enumerate() {
            denoise.push(y, row, |y, linear| out[y] = linear.to_vec());
        }
        denoise.finish(|y, linear| out[y] = linear.to_vec());
        out
    }

    fn luma(pixel: &[i32]) -> f64 {
        f64::from(LUMA[0] * pixel[0] + LUMA[1] * pixel[1] + LUMA[2] * pixel[2]) / 1024.0
    }

    // The variance of red less green and of blue less green over `rows`.
    fn chroma_variance(rows: &[Vec<i32>]) -> [f64; 2] {
        std::array::from_fn(|channel| {
            let values: Vec<f64> = rows
                .iter()
                .flat_map(|row| row.chunks_exact(3))
                .map(|pixel| f64::from(pixel[2 * channel] - pixel[1]))
                .collect();
            let mean = values.iter().sum::<f64>() / values.len() as f64;
            values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / values.len() as f64
        })
    }

    #[test]
    fn denoise_keeps_a_uniform_colour_field() {
        for (cell_size, width, height) in [(1, 7, 3), (2, 8, 6), (2, 2, 2), (1, 1, 1)] {
            let rows = vec![[30_000, 20_000, 9_000].repeat(width); height];
            assert_eq!(
                denoised(&rows, cell_size),
                rows,
                "{cell_size} {width}x{height}"
            );
        }
    }

    #[test]
    fn denoise_flattens_chroma_noise_by_its_kernel() {
        // 1-4-6-4-1 over 16 each way keeps (70/256)^2 of the variance of
        // noise independent from cell to cell; a 2x2 cell averages 4 pixels.
        let kernel = (70.0f64 / 256.0).powi(2);
        for (cell_size, kept) in [(1, kernel), (2, kernel / 4.0)] {
            let (mut red, mut blue) = (noise(4_000, 0x2545_f491), noise(4_000, 0x9e37_79b9));
            let rows: Vec<Vec<i32>> = (0..96)
                .map(|_| {
                    (0..96)
                        .flat_map(|_| [20_000 + red(), 20_000, 20_000 + blue()])
                        .collect()
                })
                .collect();
            let before = chroma_variance(&rows);
            let after = chroma_variance(&denoised(&rows, cell_size));
            for channel in 0..2 {
                let ratio = after[channel] / before[channel];
                assert!(
                    (ratio / kept - 1.0).abs() < 0.15,
                    "{cell_size}: {ratio}, {kept}"
                );
            }
        }
    }

    #[test]
    fn denoise_leaves_each_pixels_luma_and_so_a_sharp_edge() {
        let (mut red, mut blue) = (noise(3_000, 0x2545_f491), noise(3_000, 0x9e37_79b9));
        let rows: Vec<Vec<i32>> = (0..16)
            .map(|_| {
                (0..16)
                    .flat_map(|x| {
                        let grey = if x < 8 { 5_000 } else { 50_000 };
                        [grey + red(), grey, grey + blue()]
                    })
                    .collect()
            })
            .collect();
        for cell_size in [1, 2] {
            for (row, denoised_row) in rows.iter().zip(denoised(&rows, cell_size)) {
                for (pixel, denoised) in row.chunks_exact(3).zip(denoised_row.chunks_exact(3)) {
                    assert!(
                        (luma(pixel) - luma(denoised)).abs() <= 1.0,
                        "{pixel:?} {denoised:?}"
                    );
                }
            }
        }
    }
}
