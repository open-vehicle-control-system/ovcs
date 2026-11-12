//! The colour path of a sensor with a tuning, in libcamera's order: black
//! level, lens shading, white balance, demosaic on linear 16-bit values,
//! colour correction matrix, chroma denoise, then the contrast curve to 8
//! bits.

use std::ops::Range;

use crate::arguments::Output;
use crate::bands::{self, Conversion, Developed, Sums};
use crate::bayer::{self, DemosaicRows, Image, RawFrame};
use crate::tuning::{LensShading, Tuning};
use crate::white_balance::Gains;

/// The matrix that leaves colours as they are.
pub const IDENTITY: [f64; 9] = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];

/// Linear values run from 0, black, to this, the sensor's full scale.
const LINEAR_MAX: u32 = 65_535;
/// Gains are in 1/4096ths.
const GAIN_SHIFT: u32 = 12;
/// Matrix coefficients are in 1/1024ths within -8..8, the PiSP's format,
/// which keeps a row's sum of products of 16-bit values within `i32`.
const MATRIX_SHIFT: u32 = 10;
const MATRIX_LIMIT: f64 = 8.0;
/// The contrast table has an entry every 16 linear values.
const CONTRAST_SHIFT: u32 = 4;
const CONTRAST_ENTRIES: usize = (LINEAR_MAX >> CONTRAST_SHIFT) as usize + 1;
/// Interpolation weights between shading vertices are in 1/256ths.
const WEIGHT_SHIFT: u32 = 8;
const WEIGHT_ONE: u32 = 1 << WEIGHT_SHIFT;
/// Rec. 709's luma weights of linear red, green and blue, in 1/1024ths.
const LUMA: [i32; 3] = [218, 732, 74];
const LUMA_SHIFT: u32 = 10;
/// The chroma denoise takes the colour matrix's output within plus or minus
/// this, which keeps its sums within `i32`.
const DENOISE_LIMIT: i32 = 2 * LINEAR_MAX as i32;

/// The 8-bit output of a contrast curve for 16-bit linear values.
pub struct ContrastTable {
    table: Box<[u8; CONTRAST_ENTRIES]>,
}

impl ContrastTable {
    /// The table of `tuning`'s contrast curve.
    pub fn new(tuning: &Tuning) -> ContrastTable {
        ContrastTable::from_curve(|input| tuning.contrast(input))
    }

    /// The table of `curve`, from a 16-bit linear input to a 16-bit output.
    pub fn from_curve(curve: impl Fn(f64) -> f64) -> ContrastTable {
        let table = Box::new(std::array::from_fn(|entry| {
            let input = f64::from((entry as u32) << CONTRAST_SHIFT);
            (curve(input) * 255.0 / f64::from(LINEAR_MAX))
                .round()
                .clamp(0.0, 255.0) as u8
        }));
        ContrastTable { table }
    }

    /// The 8-bit output of the linear value `linear`.
    pub fn shown(&self, linear: i32) -> u8 {
        self.output(entry(linear))
    }

    /// The output of the table's `entry`th entry.
    fn output(&self, entry: u16) -> u8 {
        self.table[usize::from(entry) & (CONTRAST_ENTRIES - 1)]
    }
}

/// The contrast table's entry nearest the linear value `linear`.
fn entry(linear: i32) -> u16 {
    let half = 1 << (CONTRAST_SHIFT - 1);
    ((linear.clamp(0, LINEAR_MAX as i32) + half) >> CONTRAST_SHIFT).min(CONTRAST_ENTRIES as i32 - 1)
        as u16
}

/// How a frame's raw samples become colour.
pub struct Colour<'a> {
    /// The raw sample value of black.
    pub black_level: u16,
    pub shading: &'a LensShading,
    pub white_balance: Gains,
    pub matrix: [f64; 9],
    pub contrast: &'a ContrastTable,
    /// Blurs the chroma at the resolution of 2x2 RGGB cells, each pixel's
    /// luma kept (`ChromaDenoise`).
    pub denoise: bool,
}

/// What the colour path keeps from one frame to the next: the rows each
/// band of it works on.
#[derive(Default)]
pub struct Buffers {
    bands: Vec<Band>,
}

/// The rows a band of the colour path works on.
#[derive(Default)]
struct Band {
    shading_gains: ShadingGains,
    row_gains: Vec<u32>,
    values: [Vec<u16>; 2],
    half_row: Vec<u16>,
    demosaic: DemosaicRows<u16>,
    entries: Vec<u16>,
    matrixed: Vec<i32>,
    chroma: ChromaDenoise,
    /// The lens shading gains alone, white balance measures through, and
    /// those of a row of RGGB cells.
    measured_gains: ShadingGains,
    measured_row_gains: [Vec<u32>; 2],
}

/// `frame` through `colour` into `rgb`, through `buffers`, at the size of
/// `conversion.output`: at its own size demosaiced as `bayer::rgb_full`
/// does, on linear values, each sample's signal above the black level times
/// its lens shading and white balance gains, the sensor's full scale at
/// 65535; at half size each 2x2 RGGB cell one pixel, red, the mean of both
/// greens, and blue, on those linear values. Measures what `conversion`
/// asks for (`measure`).
pub fn develop<'b>(
    frame: &RawFrame,
    colour: &Colour,
    conversion: &Conversion,
    rgb: &'b mut Vec<u8>,
    Buffers { bands }: &mut Buffers,
) -> Developed<'b> {
    let (width, cell) = match conversion.output {
        Output::Full => (frame.width, 2),
        Output::Half => (frame.width / 2, 1),
    };
    rgb.resize(width * frame.cell_row_count() * cell * 3, 0);
    let sums = bands::convert(
        rgb,
        width,
        cell,
        conversion.rotate_180,
        conversion.threads,
        bands,
        |cells, image, band| {
            let sums = measure(frame, colour, conversion, cells.clone(), band);
            match conversion.output {
                Output::Full => full_band(frame, colour, cells, image, band),
                Output::Half => half_band(frame, colour, cells, image, band),
            }
            sums
        },
    );
    Developed::new(rgb, sums, conversion, f64::from(1u32 << GAIN_SHIFT))
}

/// Writes the rows of RGGB cells `cells` of `frame` at its own size into
/// `image`, through `band`.
fn full_band(
    frame: &RawFrame,
    colour: &Colour,
    cells: Range<usize>,
    image: Image,
    band: &mut Band,
) {
    let Band {
        shading_gains,
        row_gains,
        demosaic,
        entries,
        matrixed,
        chroma,
        ..
    } = band;
    row_gains.resize(frame.width, 0);
    let mut linear = linearisation(frame, colour, shading_gains);
    let (denoise, rows) = denoise(
        colour,
        matrixed,
        chroma,
        frame.width,
        2,
        frame.cell_row_count(),
        cells,
    );
    let mut renderer = Renderer::new(colour, image, frame.width, entries, denoise);
    bayer::demosaic_full(
        frame,
        demosaic,
        rows,
        |row, samples, values: &mut [u16]| linear.row(row, samples, row_gains, values),
        |y, pixels| renderer.row(y, pixels),
    );
    renderer.finish();
}

/// Writes the rows of RGGB cells `cells` of `frame` into `image`, each cell
/// one pixel, through `band`.
fn half_band(
    frame: &RawFrame,
    colour: &Colour,
    cells: Range<usize>,
    image: Image,
    band: &mut Band,
) {
    let Band {
        shading_gains,
        row_gains,
        values: [top_values, bottom_values],
        half_row,
        entries,
        matrixed,
        chroma,
        ..
    } = band;
    let width = frame.width / 2;
    row_gains.resize(frame.width, 0);
    top_values.resize(frame.width, 0);
    bottom_values.resize(frame.width, 0);
    half_row.resize(width * 3, 0);
    let mut linear = linearisation(frame, colour, shading_gains);
    let (denoise, rows) = denoise(
        colour,
        matrixed,
        chroma,
        width,
        1,
        frame.cell_row_count(),
        cells,
    );
    let mut renderer = Renderer::new(colour, image, width, entries, denoise);
    frame.cell_rows(rows, 1, |row, top, bottom| {
        linear.row(row, top, row_gains, top_values);
        linear.row(row + 1, bottom, row_gains, bottom_values);
        for ((top_pair, bottom_pair), pixel) in top_values
            .chunks_exact(2)
            .zip(bottom_values.chunks_exact(2))
            .zip(half_row.chunks_exact_mut(3))
        {
            pixel[0] = top_pair[0];
            pixel[1] = ((u32::from(top_pair[1]) + u32::from(bottom_pair[0]) + 1) >> 1) as u16;
            pixel[2] = bottom_pair[1];
        }
        renderer.row(row / 2, half_row);
    });
    renderer.finish();
}

/// What `conversion` asks to measure of every `conversion.row_step`-th row
/// of RGGB cells of `frame` within `cells`, through `band`: for auto
/// exposure, each cell's two greens after lens shading and white balance,
/// averaged as the half-size image does, through the contrast curve, before
/// the colour matrix; for white balance, each cell's red, greens and blue
/// above the black level, each times its lens shading gain.
fn measure(
    frame: &RawFrame,
    colour: &Colour,
    conversion: &Conversion,
    cells: Range<usize>,
    band: &mut Band,
) -> Sums {
    let mut sums = Sums::default();
    let Band {
        shading_gains,
        row_gains,
        values: [top_values, bottom_values],
        measured_gains,
        measured_row_gains: [top_gains, bottom_gains],
        ..
    } = band;
    if conversion.green_mean {
        row_gains.resize(frame.width, 0);
        top_values.resize(frame.width, 0);
        bottom_values.resize(frame.width, 0);
        let mut linear = linearisation(frame, colour, shading_gains);
        let mut measured = 0u64;
        frame.cell_rows(cells.clone(), conversion.row_step, |row, top, bottom| {
            linear.row(row, top, row_gains, top_values);
            linear.row(row + 1, bottom, row_gains, bottom_values);
            for (top_pair, bottom_pair) in top_values
                .chunks_exact(2)
                .zip(bottom_values.chunks_exact(2))
            {
                let green = (i32::from(top_pair[1]) + i32::from(bottom_pair[0]) + 1) >> 1;
                sums.green += u64::from(colour.contrast.shown(green));
                measured += 1;
            }
        });
        sums.cells = measured;
    }
    if conversion.channel_means {
        measured_gains.set(
            colour.shading,
            [1.0; 3],
            u32::MAX >> WEIGHT_SHIFT,
            frame.width,
            frame.height,
        );
        top_gains.resize(frame.width, 0);
        bottom_gains.resize(frame.width, 0);
        let black_level = colour.black_level;
        let shaded = |sample: u16, gain: u32| {
            u64::from(sample.saturating_sub(black_level)) * u64::from(gain)
        };
        let mut measured = 0u64;
        frame.cell_rows(cells, conversion.row_step, |row, top, bottom| {
            measured_gains.row(row, top_gains);
            measured_gains.row(row + 1, bottom_gains);
            for i in (0..frame.width).step_by(2) {
                sums.channels[0] += shaded(top[i], top_gains[i]);
                sums.channels[1] +=
                    shaded(top[i + 1], top_gains[i + 1]) + shaded(bottom[i], bottom_gains[i]);
                sums.channels[2] += shaded(bottom[i + 1], bottom_gains[i + 1]);
                measured += 1;
            }
        });
        sums.cells = measured;
    }
    sums
}

/// What `colour` makes of `frame`'s samples, in fixed point: their linear
/// values, through `gains`.
fn linearisation<'g>(
    frame: &RawFrame,
    colour: &Colour,
    gains: &'g mut ShadingGains,
) -> Linearisation<'g> {
    let full_scale = (1u32 << frame.layout.sample_bits()) - 1;
    let range = full_scale.saturating_sub(colour.black_level.into()).max(1);
    let white_balance = [colour.white_balance.red, 1.0, colour.white_balance.blue];
    // No channel's gain below 1, as libcamera's PiSP pipeline does, so that
    // clipped highlights stay white.
    let least = white_balance.iter().copied().fold(1.0, f64::min);
    let scale = f64::from(LINEAR_MAX) / f64::from(range) / least;
    // Keeps the gains' blends, and their products with a signal, within u32.
    let cap = (u32::MAX / range).min(u32::MAX >> WEIGHT_SHIFT);
    gains.set(
        colour.shading,
        white_balance.map(|gain| gain * scale),
        cap,
        frame.width,
        frame.height,
    );
    Linearisation {
        gains,
        black_level: colour.black_level,
    }
}

/// `matrix` in 1/1024ths within -8..8, each row's rounding put on its
/// diagonal so that the row keeps its sum and a grey stays grey.
fn fixed_matrix(matrix: [f64; 9]) -> [[i32; 3]; 3] {
    let one = f64::from(1u32 << MATRIX_SHIFT);
    std::array::from_fn(|row| {
        let limited: [f64; 3] = std::array::from_fn(|column| {
            matrix[3 * row + column].clamp(-MATRIX_LIMIT, MATRIX_LIMIT - 1e-4)
        });
        let mut fixed = limited.map(|coefficient| (coefficient * one).round() as i32);
        fixed[row] +=
            (limited.iter().sum::<f64>() * one).round() as i32 - fixed.iter().sum::<i32>();
        fixed
    })
}

/// Turns raw samples into linear values.
struct Linearisation<'g> {
    gains: &'g mut ShadingGains,
    black_level: u16,
}

impl Linearisation<'_> {
    /// The linear values of the samples of row `row`, through `row_gains`,
    /// their gains.
    fn row(&mut self, row: usize, samples: &[u16], row_gains: &mut [u32], values: &mut [u16]) {
        self.gains.row(row, row_gains);
        for ((&sample, &gain), value) in samples.iter().zip(&*row_gains).zip(values) {
            let signal = u32::from(sample.saturating_sub(self.black_level));
            *value = ((signal * gain) >> GAIN_SHIFT).min(LINEAR_MAX) as u16;
        }
    }
}

/// The chroma denoise of a frame, and the row of the colour matrix's output
/// it takes.
struct Denoise<'a> {
    matrixed: &'a mut [i32],
    chroma: &'a mut ChromaDenoise,
}

/// With `colour.denoise`, the chroma denoise of the rows of cells `cells` of
/// an image of `cell_rows` rows of cells of `size` by `size` pixels, `width`
/// pixels wide, in `matrixed` and `chroma`. Returns it, and the rows of
/// pixels to hand it (`ChromaDenoise::start`), or without it those of
/// `cells`.
fn denoise<'a>(
    colour: &Colour,
    matrixed: &'a mut Vec<i32>,
    chroma: &'a mut ChromaDenoise,
    width: usize,
    size: usize,
    cell_rows: usize,
    cells: Range<usize>,
) -> (Option<Denoise<'a>>, Range<usize>) {
    if !colour.denoise {
        return (None, size * cells.start..size * cells.end);
    }
    matrixed.resize(width * 3, 0);
    let rows = chroma.start(width, size, cell_rows, cells);
    (Some(Denoise { matrixed, chroma }), rows)
}

/// Writes rows of pixels' linear red, green and blue into an image: through
/// the colour matrix, the chroma denoise when there is one, then the
/// contrast table.
struct Renderer<'a> {
    matrix: [[i32; 3]; 3],
    contrast: &'a ContrastTable,
    image: Image<'a>,
    entries: &'a mut [u16],
    denoise: Option<Denoise<'a>>,
}

impl<'a> Renderer<'a> {
    /// The renderer of `colour` into `image`, rows of `width` pixels,
    /// through `entries` and `denoise`.
    fn new(
        colour: &Colour<'a>,
        image: Image<'a>,
        width: usize,
        entries: &'a mut Vec<u16>,
        denoise: Option<Denoise<'a>>,
    ) -> Renderer<'a> {
        entries.resize(width * 3, 0);
        Renderer {
            matrix: fixed_matrix(colour.matrix),
            contrast: colour.contrast,
            image,
            entries,
            denoise,
        }
    }

    /// Takes row `y` of pixels' linear red, green and blue, `rgb`.
    fn row(&mut self, y: usize, rgb: &[u16]) {
        let (contrast, image, entries) = (self.contrast, &mut self.image, &mut *self.entries);
        match &mut self.denoise {
            Some(Denoise { matrixed, chroma }) => {
                apply_matrix(&self.matrix, rgb, matrixed, |linear| {
                    linear.clamp(-DENOISE_LIMIT, DENOISE_LIMIT)
                });
                chroma.push(y, matrixed, |y, linear| {
                    write_linear_row(contrast, image, entries, y, linear)
                });
            }
            None => {
                apply_matrix(&self.matrix, rgb, entries, entry);
                write_row(contrast, image, y, entries);
            }
        }
    }

    /// Writes the rows the chroma denoise still holds.
    fn finish(self) {
        let (contrast, mut image, entries) = (self.contrast, self.image, self.entries);
        if let Some(Denoise { chroma, .. }) = self.denoise {
            chroma.finish(|y, linear| write_linear_row(contrast, &mut image, entries, y, linear));
        }
    }
}

/// Puts each pixel of `rgb` through `matrix` into `out`, each channel's
/// value as `store` keeps it.
fn apply_matrix<T>(matrix: &[[i32; 3]; 3], rgb: &[u16], out: &mut [T], store: impl Fn(i32) -> T) {
    let half = 1 << (MATRIX_SHIFT - 1);
    let [to_red, to_green, to_blue] = *matrix;
    // The matrix in its own loop, without lookups, runs in vector lanes.
    for (pixel, out) in rgb.chunks_exact(3).zip(out.chunks_exact_mut(3)) {
        let (red, green, blue) = (
            i32::from(pixel[0]),
            i32::from(pixel[1]),
            i32::from(pixel[2]),
        );
        let linear = |[from_red, from_green, from_blue]: [i32; 3]| {
            (from_red * red + from_green * green + from_blue * blue + half) >> MATRIX_SHIFT
        };
        out[0] = store(linear(to_red));
        out[1] = store(linear(to_green));
        out[2] = store(linear(to_blue));
    }
}

/// Writes row `y` of `image`: the contrast table's outputs of the linear
/// values `linear`, through `entries`.
fn write_linear_row(
    contrast: &ContrastTable,
    image: &mut Image,
    entries: &mut [u16],
    y: usize,
    linear: &[i32],
) {
    for (&value, entry) in linear.iter().zip(entries.iter_mut()) {
        *entry = self::entry(value);
    }
    write_row(contrast, image, y, entries);
}

/// Writes row `y` of `image`: the outputs of the contrast table's `entries`.
fn write_row(contrast: &ContrastTable, image: &mut Image, y: usize, entries: &[u16]) {
    image.write(y, |out| {
        for (&entry, out) in entries.iter().zip(out) {
            *out = contrast.output(entry);
        }
    });
}

/// Blurs the chroma of rows of pixels' linear red, green and blue and keeps
/// each pixel's luma. The chroma, red less green and blue less green, is
/// averaged over cells of `size` by `size` pixels, then blurred over cells
/// by 1-4-6-4-1 across and down, the edge cells standing in for those
/// beyond; each pixel then takes its cell's chroma around its own luma.
/// Cb and Cr are linear in red and blue less green once luma is kept, so
/// they blur alike.
#[derive(Default)]
struct ChromaDenoise {
    width: usize,
    size: usize,
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
    /// cells of `size` by `size` pixels, 1 or 2, `width` pixels wide.
    /// Returns the rows of pixels to push: those of `band` and of the two
    /// cell rows on each side of it within the image, the blur's reach.
    fn start(
        &mut self,
        width: usize,
        size: usize,
        cell_rows: usize,
        band: Range<usize>,
    ) -> Range<usize> {
        let cells = width / size;
        (self.width, self.size, self.cell_rows) = (width, size, cell_rows);
        (self.next, self.end) = (band.start, band.end.min(cell_rows));
        for luma in &mut self.luma {
            luma.resize(size * width, 0);
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
        size * self.next.saturating_sub(2)..size * (self.end + 2).min(cell_rows)
    }

    /// Takes row `y` of pixels, and hands each row of pixels of the band
    /// whose cell row's chroma is blurred, two cell rows behind, to
    /// `denoised(y, rgb)`.
    fn push(&mut self, y: usize, rgb: &[i32], mut denoised: impl FnMut(usize, &[i32])) {
        let (cell_row, row_in_cell) = (y / self.size, y % self.size);
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
        if self.size == 2 {
            add_chroma::<2>(rgb, &mut self.sums);
        } else {
            add_chroma::<1>(rgb, &mut self.sums);
        }
        if row_in_cell + 1 == self.size {
            self.blur_across(cell_row);
            if self.next < self.end && cell_row >= self.next + 2 {
                self.hand_out(&mut denoised);
            }
        }
    }

    /// Hands the band's rows still held to `denoised(y, rgb)`.
    fn finish(&mut self, mut denoised: impl FnMut(usize, &[i32])) {
        while self.next < self.end {
            self.hand_out(&mut denoised);
        }
    }

    /// Averages the chroma of cell row `cell_row` over its cells and blurs
    /// it across.
    fn blur_across(&mut self, cell_row: usize) {
        let shift = 2 * self.size.trailing_zeros();
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
            size,
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
        for row_in_cell in 0..*size {
            let luma = &luma[cell_row % 3][row_in_cell * *width..(row_in_cell + 1) * *width];
            if *size == 2 {
                rebuild::<2>(luma, blurred, out);
            } else {
                rebuild::<1>(luma, blurred, out);
            }
            denoised(cell_row * *size + row_in_cell, out);
        }
    }
}

/// Adds the chroma of each cell of `SIZE` pixels of `rgb` to `sums`.
fn add_chroma<const SIZE: usize>(rgb: &[i32], [red_sums, blue_sums]: &mut [Vec<i32>; 2]) {
    for ((cell, red), blue) in rgb
        .chunks_exact(3 * SIZE)
        .zip(red_sums.iter_mut())
        .zip(blue_sums.iter_mut())
    {
        for pixel in cell.chunks_exact(3) {
            *red += pixel[0] - pixel[1];
            *blue += pixel[2] - pixel[1];
        }
    }
}

/// Writes to `out` each pixel of cells of `SIZE` pixels with its cell's
/// `chroma` around its own `luma`.
fn rebuild<const SIZE: usize>(luma: &[i32], [red, blue]: &[Vec<i32>; 2], out: &mut [i32]) {
    let half = 1 << (LUMA_SHIFT - 1);
    for (((pixels, lumas), &red), &blue) in out
        .chunks_exact_mut(3 * SIZE)
        .zip(luma.chunks_exact(SIZE))
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

/// The gain of each sample of a frame, in 1/4096ths, bilinear between gains
/// at the vertices of a grid over the frame.
#[derive(Default)]
struct ShadingGains {
    columns: usize,
    rows: usize,
    height: usize,
    vertices: [Vec<u32>; 3],
    /// Each sample column's vertex on its left, and the weight of the one on
    /// its right.
    column_vertex: Vec<usize>,
    column_weight: Vec<u32>,
    /// The gains at the vertices of a sample row's two channels, between the
    /// vertex rows above and below it.
    row_vertices: [Vec<u32>; 2],
}

impl ShadingGains {
    /// The gains of `shading`, each channel's times `channel_gains`, each at
    /// most `cap`, on a frame of `width` by `height` samples.
    #[cfg(test)]
    fn new(
        shading: &LensShading,
        channel_gains: [f64; 3],
        cap: u32,
        width: usize,
        height: usize,
    ) -> ShadingGains {
        let mut gains = ShadingGains::default();
        gains.set(shading, channel_gains, cap, width, height);
        gains
    }

    /// Becomes the gains `new` gives, in the rows it already holds.
    fn set(
        &mut self,
        shading: &LensShading,
        channel_gains: [f64; 3],
        cap: u32,
        width: usize,
        height: usize,
    ) {
        for (channel, vertices) in self.vertices.iter_mut().enumerate() {
            vertices.clear();
            vertices.extend(shading.gains[channel].iter().map(|gain| {
                (gain * channel_gains[channel] * f64::from(1u32 << GAIN_SHIFT))
                    .round()
                    .min(f64::from(cap)) as u32
            }));
        }
        self.column_vertex.clear();
        self.column_weight.clear();
        for column in 0..width {
            let (vertex, weight) = vertex_and_weight(column, width, shading.columns - 1);
            self.column_vertex.push(vertex);
            self.column_weight.push(weight);
        }
        for row_vertices in &mut self.row_vertices {
            row_vertices.resize(shading.columns, 0);
        }
        (self.columns, self.rows, self.height) = (shading.columns, shading.rows, height);
    }

    /// Fills `gains` with the gain of each sample of row `row`: red's and
    /// green's on an even row, green's and blue's on an odd one.
    fn row(&mut self, row: usize, gains: &mut [u32]) {
        let (above, weight) = vertex_and_weight(row, self.height, self.rows - 1);
        let channels = if row.is_multiple_of(2) {
            [0, 1]
        } else {
            [1, 2]
        };
        for (row_vertices, channel) in self.row_vertices.iter_mut().zip(channels) {
            let vertices = &self.vertices[channel];
            let top = &vertices[above * self.columns..(above + 1) * self.columns];
            let bottom = &vertices[(above + 1) * self.columns..(above + 2) * self.columns];
            for ((gain, &top), &bottom) in row_vertices.iter_mut().zip(top).zip(bottom) {
                *gain = (top * (WEIGHT_ONE - weight) + bottom * weight) >> WEIGHT_SHIFT;
            }
        }
        let [even, odd] = &self.row_vertices;
        let between = |vertices: &[u32], left: usize, weight: u32| {
            (vertices[left] * (WEIGHT_ONE - weight) + vertices[left + 1] * weight) >> WEIGHT_SHIFT
        };
        for ((pair, left), weight) in gains
            .chunks_exact_mut(2)
            .zip(self.column_vertex.chunks_exact(2))
            .zip(self.column_weight.chunks_exact(2))
        {
            pair[0] = between(even, left[0], weight[0]);
            pair[1] = between(odd, left[1], weight[1]);
        }
    }
}

/// The vertex before the centre of sample `index` of `count` on a grid of
/// `cells` cells over them, and the weight of the vertex after it.
fn vertex_and_weight(index: usize, count: usize, cells: usize) -> (usize, u32) {
    let position = (((2 * index + 1) * cells) << WEIGHT_SHIFT) / (2 * count);
    (
        position >> WEIGHT_SHIFT,
        (position as u32) & (WEIGHT_ONE - 1),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bayer::tests::padded_packed12;
    use crate::bayer::Layout;
    use crate::tuning::imx477;
    use crate::white_balance;

    const TUNING: &Tuning = &imx477::TUNING;
    const BLACK: u16 = 256;
    const UNITY: Gains = Gains {
        red: 1.0,
        blue: 1.0,
    };

    // Packed 12-bit rows of `samples`, padded by 4 bytes.
    fn packed(samples: &[u16], width: usize) -> Vec<u8> {
        padded_packed12(samples, width, width * 3 / 2 + 4)
    }

    fn frame(raw: &[u8], width: usize, height: usize) -> RawFrame<'_> {
        RawFrame {
            raw,
            width,
            height,
            row_stride: width * 3 / 2 + 4,
            layout: Layout::Packed12,
        }
    }

    // Every RGGB cell `cell`.
    fn uniform(cell: [u16; 4], width: usize, height: usize) -> Vec<u16> {
        (0..height)
            .flat_map(|y| (0..width).map(move |x| cell[(y % 2) * 2 + x % 2]))
            .collect()
    }

    // The samples of a grey scene of `signal` above `BLACK` seen through
    // `shading` under a light that `light` balances.
    fn grey_scene(
        signal: f64,
        shading: &LensShading,
        light: Gains,
        width: usize,
        height: usize,
    ) -> Vec<u16> {
        let mut gains = ShadingGains::new(shading, [1.0; 3], u32::MAX >> 8, width, height);
        let mut row_gains = vec![0u32; width];
        let mut samples = Vec::with_capacity(width * height);
        for y in 0..height {
            gains.row(y, &mut row_gains);
            for (x, &gain_q12) in row_gains.iter().enumerate() {
                let white_balance = match (y % 2, x % 2) {
                    (0, 0) => light.red,
                    (1, 1) => light.blue,
                    _ => 1.0,
                };
                let shading = f64::from(gain_q12) / 4096.0;
                samples.push(BLACK + (signal / (shading * white_balance)).round() as u16);
            }
        }
        samples
    }

    fn linear() -> ContrastTable {
        ContrastTable::from_curve(|x| x)
    }

    #[test]
    fn a_grey_scene_comes_out_grey_whatever_its_light_and_the_lens() {
        let (width, height) = (64, 48);
        // The light of 4559 K on the tuning's curve.
        let light = Gains {
            red: 1.0 / 0.3031,
            blue: 1.0 / 0.6573,
        };
        let lens = TUNING.lens_shading(4559.0);
        let raw = packed(&grey_scene(2400.0, &lens, light, width, height), width);
        let frame = frame(&raw, width, height);

        let gains = white_balance::grey_world(shaded_channel_means(&frame, BLACK, &lens, 1), UNITY);
        let kelvin = TUNING.colour_temperature(gains);
        let shading = TUNING.lens_shading(kelvin);
        let contrast = ContrastTable::new(TUNING);
        let colour = |denoise| Colour {
            black_level: BLACK,
            shading: &shading,
            white_balance: gains,
            matrix: TUNING.colour_matrix(kelvin),
            contrast: &contrast,
            denoise,
        };

        assert!((gains.red / light.red - 1.0).abs() < 0.005, "{gains:?}");
        assert!((gains.blue / light.blue - 1.0).abs() < 0.005, "{gains:?}");
        for rgb in [true, false].into_iter().flat_map(|denoise| {
            [
                full(&frame, &colour(denoise), false),
                half(&frame, &colour(denoise), false),
            ]
        }) {
            for pixel in rgb.chunks_exact(3) {
                let (least, most) = (pixel.iter().min().unwrap(), pixel.iter().max().unwrap());
                assert!(most - least <= 1, "{pixel:?}");
                assert!((200..=225).contains(least), "{pixel:?}");
            }
        }
    }

    #[test]
    fn black_stays_black() {
        let raw = packed(&[BLACK; 8 * 4], 8);
        let shading = TUNING.lens_shading(4000.0);
        let contrast = ContrastTable::new(TUNING);
        let colour = Colour {
            black_level: BLACK,
            shading: &shading,
            white_balance: Gains {
                red: 2.0,
                blue: 1.5,
            },
            matrix: TUNING.colour_matrix(4000.0),
            contrast: &contrast,
            denoise: true,
        };
        assert_eq!(full(&frame(&raw, 8, 4), &colour, false), [0; 8 * 4 * 3]);
        assert_eq!(half(&frame(&raw, 8, 4), &colour, false), [0; 4 * 2 * 3]);
    }

    #[test]
    fn clipped_highlights_stay_white_whatever_the_white_balance() {
        let raw = packed(&[4095; 8 * 4], 8);
        let shading = TUNING.lens_shading(4000.0);
        let contrast = ContrastTable::new(TUNING);
        let colour = Colour {
            black_level: BLACK,
            shading: &shading,
            white_balance: Gains {
                red: 0.6,
                blue: 1.8,
            },
            matrix: TUNING.colour_matrix(4000.0),
            contrast: &contrast,
            denoise: true,
        };
        assert_eq!(full(&frame(&raw, 8, 4), &colour, false), [255; 8 * 4 * 3]);
        assert_eq!(half(&frame(&raw, 8, 4), &colour, false), [255; 4 * 2 * 3]);
    }

    #[test]
    fn each_output_channel_is_made_by_its_row_of_the_matrix() {
        let raw = packed(&uniform([1000, 2000, 2000, 3000], 4, 4), 4);
        let shading = LensShading::none();
        let contrast = linear();
        let with = |matrix| Colour {
            black_level: 0,
            shading: &shading,
            white_balance: UNITY,
            matrix,
            contrast: &contrast,
            denoise: true,
        };
        // Red from green, green from blue, blue from red.
        let turned = [0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0];

        let upright = full(&frame(&raw, 4, 4), &with(IDENTITY), false);
        let mixed = full(&frame(&raw, 4, 4), &with(turned), false);

        // 1000, 2000 and 3000 of 4095.
        assert_eq!(upright, [62, 125, 187].repeat(16));
        assert_eq!(mixed, [125, 187, 62].repeat(16));
    }

    #[test]
    fn a_matrix_whose_rows_each_sum_to_one_keeps_a_grey_grey() {
        // Each row's coefficients round to 1/1024ths summing to more than 1.
        let matrix = [
            0.4996, 0.4996, 0.0008, //
            0.0008, 0.4996, 0.4996, //
            0.4996, 0.0008, 0.4996,
        ];
        // 2047 of 4095 lies just below a step of the contrast table.
        let raw = packed(&[2047; 4 * 4], 4);
        let shading = LensShading::none();
        let contrast = linear();
        let colour = Colour {
            black_level: 0,
            shading: &shading,
            white_balance: UNITY,
            matrix,
            contrast: &contrast,
            denoise: true,
        };
        assert_eq!(full(&frame(&raw, 4, 4), &colour, false), [127; 4 * 4 * 3]);
    }

    #[test]
    fn each_channel_takes_its_own_lens_shading_gain() {
        let shading = LensShading {
            columns: 2,
            rows: 2,
            gains: [vec![2.0; 4], vec![1.0; 4], vec![1.5; 4]],
        };
        let raw = packed(&[1000; 8 * 4], 8);
        let frame = frame(&raw, 8, 4);
        let contrast = linear();
        assert_eq!(
            shaded_channel_means(&frame, 0, &shading, 1),
            [2000.0, 1000.0, 1500.0]
        );
        for denoise in [true, false] {
            let colour = Colour {
                black_level: 0,
                shading: &shading,
                white_balance: UNITY,
                matrix: IDENTITY,
                contrast: &contrast,
                denoise,
            };
            // 2000, 1000 and 1500 of 4095.
            assert_eq!(full(&frame, &colour, false), [125, 62, 93].repeat(32));
            assert_eq!(half(&frame, &colour, false), [125, 62, 93].repeat(8));
        }
    }

    #[test]
    fn lens_shading_gains_are_interpolated_across_the_frame_from_the_grid_corners() {
        // Green from 1 at the left edge to 2 at the right, blue from 1 at the
        // top to 3 at the bottom.
        let shading = LensShading {
            columns: 2,
            rows: 2,
            gains: [
                vec![1.0; 4],
                vec![1.0, 2.0, 1.0, 2.0],
                vec![1.0, 1.0, 3.0, 3.0],
            ],
        };
        let raw = packed(&[1000; 8 * 4], 8);
        // Green is sampled at (2x + 1) / 16 across the frame, 1/2 on average;
        // blue on rows 1 and 3 of 4, at 3/8 and 7/8 of its height.
        assert_eq!(
            shaded_channel_means(&frame(&raw, 8, 4), 0, &shading, 1),
            [
                1000.0,
                1500.0,
                1000.0 * (1.0 + 2.0 * (3.0 / 8.0 + 7.0 / 8.0) / 2.0)
            ]
        );
    }

    #[test]
    fn a_rotated_image_is_the_upright_one_turned_by_180_degrees() {
        let (width, height) = (8, 6);
        let samples: Vec<u16> = (0..width * height)
            .map(|i| BLACK + ((i * 397) % 1500) as u16)
            .collect();
        let raw = packed(&samples, width);
        let frame = frame(&raw, width, height);
        let shading = TUNING.lens_shading(3000.0);
        let contrast = ContrastTable::new(TUNING);
        let turned =
            |rgb: Vec<u8>| -> Vec<u8> { rgb.chunks_exact(3).rev().flatten().copied().collect() };
        for denoise in [true, false] {
            let colour = Colour {
                black_level: BLACK,
                shading: &shading,
                white_balance: Gains {
                    red: 2.2,
                    blue: 1.6,
                },
                matrix: TUNING.colour_matrix(3000.0),
                contrast: &contrast,
                denoise,
            };
            assert_eq!(
                full(&frame, &colour, true),
                turned(full(&frame, &colour, false))
            );
            assert_eq!(
                half(&frame, &colour, true),
                turned(half(&frame, &colour, false))
            );
        }
    }

    #[test]
    fn buffers_reused_for_another_frame_give_its_own_image() {
        let samples: Vec<u16> = (0..8 * 6)
            .map(|i| BLACK + ((i * 397) % 1500) as u16)
            .collect();
        let (raw, other_raw) = (packed(&samples, 8), packed(&samples[..4 * 4], 4));
        let shading = TUNING.lens_shading(3000.0);
        let contrast = ContrastTable::new(TUNING);
        let colour = Colour {
            black_level: BLACK,
            shading: &shading,
            white_balance: Gains {
                red: 2.2,
                blue: 1.6,
            },
            matrix: TUNING.colour_matrix(3000.0),
            contrast: &contrast,
            denoise: true,
        };
        let (frame, other) = (frame(&raw, 8, 6), frame(&other_raw, 4, 4));
        let (mut rgb, mut buffers) = (Vec::new(), Buffers::default());
        rgb_full(&frame, &colour, false, &mut rgb, &mut buffers);
        assert_eq!(
            rgb_half(&other, &colour, true, &mut rgb, &mut buffers),
            half(&other, &colour, true)
        );
        assert_eq!(
            rgb_full(&other, &colour, false, &mut rgb, &mut buffers),
            full(&other, &colour, false)
        );
        assert_eq!(
            rgb_full(&frame, &colour, false, &mut rgb, &mut buffers),
            full(&frame, &colour, false)
        );
    }

    #[test]
    fn a_linear_value_takes_the_contrast_entry_nearest_it() {
        // Black at the entry of 1600, white at the entry of 1616.
        let step = ContrastTable::from_curve(|x| if x < 1608.0 { 0.0 } else { 65535.0 });
        assert_eq!(step.shown(1607), 0);
        assert_eq!(step.shown(1608), 255);
        assert_eq!(step.shown(-50), 0);
        assert_eq!(step.shown(70_000), 255);
    }

    #[test]
    fn each_contrast_entry_is_the_curve_at_16_times_its_index() {
        let step = ContrastTable::from_curve(|x| if x <= 16_000.0 { 0.0 } else { 65535.0 });
        assert_eq!(step.shown(16_000), 0);
        assert_eq!(step.shown(16_016), 255);
        assert_eq!(linear().shown(65_535), 255);
    }

    #[test]
    fn auto_exposure_measures_the_green_after_lens_shading_through_the_curve() {
        let shading = LensShading {
            columns: 2,
            rows: 2,
            gains: [vec![3.0; 4], vec![1.5; 4], vec![1.0; 4]],
        };
        let raw = packed(&uniform([3000, 1000, 1000, 500], 8, 8), 8);
        let contrast = ContrastTable::from_curve(|x| (x / 65535.0).sqrt() * 65535.0);
        let colour = Colour {
            black_level: 0,
            shading: &shading,
            white_balance: Gains {
                red: 0.8,
                blue: 1.0,
            },
            matrix: IDENTITY,
            contrast: &contrast,
            denoise: true,
        };
        let frame = frame(&raw, 8, 8);
        let mut buffers = Buffers::default();
        // Green 1000 of 4095 times its shading gain 1.5, over 0.8 for red's
        // gain to be at least 1: 30006 of 65535, whose square root is 0.677.
        assert_eq!(shown_green_mean(&frame, &colour, 1, &mut buffers), 173.0);
        assert_eq!(shown_green_mean(&frame, &colour, 2, &mut buffers), 173.0);
        assert_eq!(half(&frame, &colour, false)[1], 173);
    }

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
    // cells of `size` by `size` pixels.
    fn denoised(rows: &[Vec<i32>], size: usize) -> Vec<Vec<i32>> {
        let mut denoise = ChromaDenoise::default();
        let cell_rows = rows.len() / size;
        denoise.start(rows[0].len() / 3, size, cell_rows, 0..cell_rows);
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
        for (size, width, height) in [(1, 7, 3), (2, 8, 6), (2, 2, 2), (1, 1, 1)] {
            let rows = vec![[30_000, 20_000, 9_000].repeat(width); height];
            assert_eq!(denoised(&rows, size), rows, "{size} {width}x{height}");
        }
    }

    #[test]
    fn denoise_flattens_chroma_noise_by_its_kernel() {
        // 1-4-6-4-1 over 16 each way keeps (70/256)^2 of the variance of
        // noise independent from cell to cell; a 2x2 cell averages 4 pixels.
        let kernel = (70.0f64 / 256.0).powi(2);
        for (size, kept) in [(1, kernel), (2, kernel / 4.0)] {
            let (mut red, mut blue) = (noise(4_000, 0x2545_f491), noise(4_000, 0x9e37_79b9));
            let rows: Vec<Vec<i32>> = (0..96)
                .map(|_| {
                    (0..96)
                        .flat_map(|_| [20_000 + red(), 20_000, 20_000 + blue()])
                        .collect()
                })
                .collect();
            let before = chroma_variance(&rows);
            let after = chroma_variance(&denoised(&rows, size));
            for channel in 0..2 {
                let ratio = after[channel] / before[channel];
                assert!((ratio / kept - 1.0).abs() < 0.15, "{size}: {ratio}, {kept}");
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
        for size in [1, 2] {
            for (row, denoised_row) in rows.iter().zip(denoised(&rows, size)) {
                for (pixel, denoised) in row.chunks_exact(3).zip(denoised_row.chunks_exact(3)) {
                    assert!(
                        (luma(pixel) - luma(denoised)).abs() <= 1.0,
                        "{pixel:?} {denoised:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn a_denoised_image_has_less_coloured_speckle() {
        let samples: Vec<u16> = (0..32 * 32)
            .map(|i| BLACK + 200 + ((i * 7919) % 400) as u16)
            .collect();
        let raw = packed(&samples, 32);
        let frame = frame(&raw, 32, 32);
        let shading = LensShading::none();
        let contrast = linear();
        let colour = |denoise| Colour {
            black_level: BLACK,
            shading: &shading,
            white_balance: UNITY,
            matrix: IDENTITY,
            contrast: &contrast,
            denoise,
        };
        // Each pixel's spread between its channels, summed.
        let speckle = |rgb: Vec<u8>| -> u32 {
            rgb.chunks_exact(3)
                .map(|pixel| u32::from(pixel.iter().max().unwrap() - pixel.iter().min().unwrap()))
                .sum()
        };
        for render in [full, half] {
            assert!(
                speckle(render(&frame, &colour(true), false)) * 2
                    < speckle(render(&frame, &colour(false), false))
            );
        }
    }

    fn full(frame: &RawFrame, colour: &Colour, rotate_180: bool) -> Vec<u8> {
        rgb_full(
            frame,
            colour,
            rotate_180,
            &mut Vec::new(),
            &mut Buffers::default(),
        )
        .to_vec()
    }

    fn half(frame: &RawFrame, colour: &Colour, rotate_180: bool) -> Vec<u8> {
        rgb_half(
            frame,
            colour,
            rotate_180,
            &mut Vec::new(),
            &mut Buffers::default(),
        )
        .to_vec()
    }

    fn conversion(output: Output, rotate_180: bool) -> Conversion {
        Conversion {
            output,
            rotate_180,
            channel_means: false,
            green_mean: false,
            row_step: 1,
            threads: 1,
        }
    }

    fn rgb_full<'b>(
        frame: &RawFrame,
        colour: &Colour,
        rotate_180: bool,
        rgb: &'b mut Vec<u8>,
        buffers: &mut Buffers,
    ) -> &'b [u8] {
        develop(
            frame,
            colour,
            &conversion(Output::Full, rotate_180),
            rgb,
            buffers,
        )
        .rgb
    }

    fn rgb_half<'b>(
        frame: &RawFrame,
        colour: &Colour,
        rotate_180: bool,
        rgb: &'b mut Vec<u8>,
        buffers: &mut Buffers,
    ) -> &'b [u8] {
        develop(
            frame,
            colour,
            &conversion(Output::Half, rotate_180),
            rgb,
            buffers,
        )
        .rgb
    }

    // The mean green auto exposure steers over every `row_step`-th row of
    // RGGB cells.
    fn shown_green_mean(
        frame: &RawFrame,
        colour: &Colour,
        row_step: usize,
        buffers: &mut Buffers,
    ) -> f64 {
        let conversion = Conversion {
            green_mean: true,
            row_step,
            ..conversion(Output::Half, false)
        };
        develop(frame, colour, &conversion, &mut Vec::new(), buffers)
            .green_mean
            .unwrap()
    }

    // The mean red, green and blue above `black_level` over every
    // `row_step`-th row of RGGB cells, each sample times its lens shading
    // gain.
    fn shaded_channel_means(
        frame: &RawFrame,
        black_level: u16,
        shading: &LensShading,
        row_step: usize,
    ) -> [f64; 3] {
        let contrast = linear();
        let colour = Colour {
            black_level,
            shading,
            white_balance: UNITY,
            matrix: IDENTITY,
            contrast: &contrast,
            denoise: false,
        };
        let conversion = Conversion {
            channel_means: true,
            row_step,
            ..conversion(Output::Half, false)
        };
        develop(
            frame,
            &colour,
            &conversion,
            &mut Vec::new(),
            &mut Buffers::default(),
        )
        .channel_means
        .unwrap()
    }
}
