//! The colour path of a sensor with a tuning, in libcamera's order: black
//! level, lens shading, white balance, demosaic on linear 16-bit values,
//! colour correction matrix, chroma denoise, then the contrast curve to 8
//! bits.

mod denoise;
mod shading;

use std::ops::Range;

use crate::arguments::Output;
use crate::bands::{self, Conversion, Images, Measures, Sums};
use crate::bayer::{self, CellRowSamples, DemosaicRows, Image, RawFrame};
use crate::tuning::{LensShading, Tuning};
use crate::white_balance::Gains;

use denoise::ChromaDenoise;
use shading::{ShadingGains, WEIGHT_SHIFT};

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
    cells: CellRowSamples,
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

/// `frame` through `colour` into `images`' `rgb`, 8-bit red, green and blue
/// per pixel, row-major, through `buffers`, at the size of
/// `conversion.output`: at its own size demosaiced as `bayer::rgb_full`
/// does, on linear values, each sample's signal above the black level times
/// its lens shading and white balance gains, the sensor's full scale at
/// 65535; at half size each 2x2 RGGB cell one pixel, red, the mean of both
/// greens, and blue, on those linear values. Measures what `conversion`
/// asks for (`measure`).
pub fn develop(
    frame: &RawFrame,
    colour: &Colour,
    conversion: &Conversion,
    images: Images,
    Buffers { bands }: &mut Buffers,
) -> Measures {
    let (width, cell_size) = match conversion.output {
        Output::Full => (frame.width, 2),
        Output::Half => (frame.width / 2, 1),
    };
    images
        .rgb
        .resize(width * frame.cell_row_count() * cell_size * 3, 0);
    let sums = bands::convert(
        images,
        width,
        cell_size,
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
    Measures::new(sums, conversion, f64::from(1u32 << GAIN_SHIFT))
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
        cells: raw_rows,
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
    frame.for_each_cell_row(rows, 1, raw_rows, |row, top, bottom| {
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
    let Band {
        cells: raw_rows,
        shading_gains,
        row_gains,
        values: [top_values, bottom_values],
        measured_gains,
        measured_row_gains: [top_gains, bottom_gains],
        ..
    } = band;
    let mut linear = conversion.green_mean.then(|| {
        row_gains.resize(frame.width, 0);
        top_values.resize(frame.width, 0);
        bottom_values.resize(frame.width, 0);
        linearisation(frame, colour, shading_gains)
    });
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
    }
    let black_level = colour.black_level;
    let shaded =
        |sample: u16, gain: u32| u64::from(sample.saturating_sub(black_level)) * u64::from(gain);
    Sums::measured(
        frame,
        conversion,
        cells,
        raw_rows,
        |row, top, bottom, sums| {
            if let Some(linear) = &mut linear {
                linear.row(row, top, row_gains, top_values);
                linear.row(row + 1, bottom, row_gains, bottom_values);
                for (top_pair, bottom_pair) in top_values
                    .chunks_exact(2)
                    .zip(bottom_values.chunks_exact(2))
                {
                    let green = (i32::from(top_pair[1]) + i32::from(bottom_pair[0]) + 1) >> 1;
                    sums.green += u64::from(colour.contrast.shown(green));
                }
            }
            if conversion.channel_means {
                measured_gains.row(row, top_gains);
                measured_gains.row(row + 1, bottom_gains);
                for i in (0..frame.width).step_by(2) {
                    sums.channels[0] += shaded(top[i], top_gains[i]);
                    sums.channels[1] +=
                        shaded(top[i + 1], top_gains[i + 1]) + shaded(bottom[i], bottom_gains[i]);
                    sums.channels[2] += shaded(bottom[i + 1], bottom_gains[i + 1]);
                }
            }
        },
    )
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
/// an image of `cell_rows` rows of cells of `cell_size` by `cell_size` pixels, `width`
/// pixels wide, in `matrixed` and `chroma`. Returns it, and the rows of
/// pixels to hand it (`ChromaDenoise::start`), or without it those of
/// `cells`.
fn denoise<'a>(
    colour: &Colour,
    matrixed: &'a mut Vec<i32>,
    chroma: &'a mut ChromaDenoise,
    width: usize,
    cell_size: usize,
    cell_rows: usize,
    cells: Range<usize>,
) -> (Option<Denoise<'a>>, Range<usize>) {
    if !colour.denoise {
        return (None, cell_size * cells.start..cell_size * cells.end);
    }
    matrixed.resize(width * 3, 0);
    let rows = chroma.start(width, cell_size, cell_rows, cells);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bayer::tests::padded_packed12;
    use crate::bayer::Layout;
    use crate::sensor::{Rectangle, SensorCrop};
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
    fn a_cropped_modes_grey_scene_comes_out_grey_through_the_lens_shading_of_its_crop() {
        let (sensor_width, sensor_height) = (64, 48);
        let crop = Rectangle {
            left: 16,
            top: 12,
            width: 32,
            height: 24,
        };
        let light = Gains {
            red: 1.0 / 0.3031,
            blue: 1.0 / 0.6573,
        };
        let lens = TUNING.lens_shading(4559.0);
        let scene = grey_scene(2400.0, &lens, light, sensor_width, sensor_height);
        let cropped: Vec<u16> = (scene.chunks_exact(sensor_width))
            .skip(crop.top as usize)
            .take(crop.height as usize)
            .flat_map(|row| &row[crop.left as usize..][..crop.width as usize])
            .copied()
            .collect();
        let (width, height) = (crop.width as usize, crop.height as usize);
        let raw = packed(&cropped, width);
        let shading = lens.cropped(&SensorCrop {
            crop,
            bounds: Rectangle {
                left: 0,
                top: 0,
                width: sensor_width as u32,
                height: sensor_height as u32,
            },
        });
        let contrast = ContrastTable::new(TUNING);
        let colour = Colour {
            black_level: BLACK,
            shading: &shading,
            white_balance: light,
            matrix: TUNING.colour_matrix(4559.0),
            contrast: &contrast,
            denoise: false,
        };

        let rgb = full(&frame(&raw, width, height), &colour, false);
        let (least, most) = (rgb.iter().min().unwrap(), rgb.iter().max().unwrap());
        assert!(most - least <= 1, "{least} to {most}");
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
            Images {
                rgb,
                averaged: None,
                nv12: None,
            },
            buffers,
        );
        rgb
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
            Images {
                rgb,
                averaged: None,
                nv12: None,
            },
            buffers,
        );
        rgb
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
        develop(
            frame,
            colour,
            &conversion,
            Images {
                rgb: &mut Vec::new(),
                averaged: None,
                nv12: None,
            },
            buffers,
        )
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
            Images {
                rgb: &mut Vec::new(),
                averaged: None,
                nv12: None,
            },
            &mut Buffers::default(),
        )
        .channel_means
        .unwrap()
    }
}
