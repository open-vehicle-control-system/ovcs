//! The colour path of a sensor with a tuning, in libcamera's order: black
//! level, lens shading, white balance, demosaic on linear 16-bit values,
//! colour correction matrix, then the contrast curve to 8 bits.

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
        let last = (CONTRAST_ENTRIES - 1) as f64;
        let table = Box::new(std::array::from_fn(|entry| {
            let input = entry as f64 * f64::from(LINEAR_MAX) / last;
            (curve(input) * 255.0 / f64::from(LINEAR_MAX))
                .round()
                .clamp(0.0, 255.0) as u8
        }));
        ContrastTable { table }
    }

    /// The output of the table's `entry`th entry.
    fn output(&self, entry: u16) -> u8 {
        self.table[usize::from(entry) & (CONTRAST_ENTRIES - 1)]
    }
}

/// The contrast table's entry of the linear value `linear`.
fn entry(linear: i32) -> u16 {
    (linear.clamp(0, LINEAR_MAX as i32) >> CONTRAST_SHIFT) as u16
}

/// How a frame's raw samples become colour.
pub struct Colour<'a> {
    /// The raw sample value of black.
    pub black_level: u16,
    pub shading: &'a LensShading,
    pub white_balance: Gains,
    pub matrix: [f64; 9],
    pub contrast: &'a ContrastTable,
}

/// What the colour path keeps from one frame to the next: the rows it works
/// on and the image it writes.
#[derive(Default)]
pub struct Buffers {
    rgb: Vec<u8>,
    shading_gains: ShadingGains,
    row_gains: Vec<u32>,
    values: [Vec<u16>; 2],
    cells: Vec<u16>,
    demosaic: DemosaicRows<u16>,
    entries: Vec<u16>,
}

/// Demosaics `frame` at its own size as `bayer::rgb_full` does, on linear
/// values: each sample's signal above the black level times its lens
/// shading and white balance gains, the sensor's full scale at 65535.
/// `rotate_180` turns the image for a sensor mounted upside down. Returns
/// 8-bit red, green and blue per pixel, row-major, in `buffers`.
pub fn rgb_full<'b>(
    frame: &RawFrame,
    colour: &Colour,
    rotate_180: bool,
    buffers: &'b mut Buffers,
) -> &'b [u8] {
    let Buffers {
        rgb,
        shading_gains,
        row_gains,
        demosaic,
        entries,
        ..
    } = buffers;
    rgb.resize(frame.width * frame.height * 3, 0);
    row_gains.resize(frame.width, 0);
    let mut linear = linearisation(frame, colour, shading_gains);
    let image = Image::new(rgb, frame.width, rotate_180);
    let mut renderer = Renderer::new(colour, image, frame.width, entries);
    bayer::demosaic_full(
        frame,
        demosaic,
        |row, samples, values: &mut [u16]| linear.row(row, samples, row_gains, values),
        |y, pixels| renderer.row(y, pixels),
    );
    rgb
}

/// Turns each 2x2 RGGB cell of `frame` into one pixel: red, the mean of
/// both greens, and blue, on linear values as `rgb_full` does. Halves both
/// dimensions; `rotate_180` turns the image for a sensor mounted upside
/// down. Returns 8-bit red, green and blue per pixel, row-major, in
/// `buffers`.
pub fn rgb_half<'b>(
    frame: &RawFrame,
    colour: &Colour,
    rotate_180: bool,
    buffers: &'b mut Buffers,
) -> &'b [u8] {
    let Buffers {
        rgb,
        shading_gains,
        row_gains,
        values: [top_values, bottom_values],
        cells,
        entries,
        ..
    } = buffers;
    let (width, height) = (frame.width / 2, frame.height / 2);
    rgb.resize(width * height * 3, 0);
    row_gains.resize(frame.width, 0);
    top_values.resize(frame.width, 0);
    bottom_values.resize(frame.width, 0);
    cells.resize(width * 3, 0);
    let mut linear = linearisation(frame, colour, shading_gains);
    let image = Image::new(rgb, width, rotate_180);
    let mut renderer = Renderer::new(colour, image, width, entries);
    frame.cell_rows(1, |row, top, bottom| {
        linear.row(row, top, row_gains, top_values);
        linear.row(row + 1, bottom, row_gains, bottom_values);
        for ((top_pair, bottom_pair), cell) in top_values
            .chunks_exact(2)
            .zip(bottom_values.chunks_exact(2))
            .zip(cells.chunks_exact_mut(3))
        {
            cell[0] = top_pair[0];
            cell[1] = ((u32::from(top_pair[1]) + u32::from(bottom_pair[0]) + 1) >> 1) as u16;
            cell[2] = bottom_pair[1];
        }
        renderer.row(row / 2, cells);
    });
    rgb
}

/// The mean red, green and blue above `black_level` over every
/// `row_step`-th row of RGGB cells of `frame`, each sample times its lens
/// shading gain.
pub fn shaded_channel_means(
    frame: &RawFrame,
    black_level: u16,
    shading: &LensShading,
    row_step: usize,
) -> [f64; 3] {
    let mut gains = ShadingGains::new(
        shading,
        [1.0; 3],
        u32::MAX >> WEIGHT_SHIFT,
        frame.width,
        frame.height,
    );
    let (mut top_gains, mut bottom_gains) = (vec![0u32; frame.width], vec![0u32; frame.width]);
    let mut sums = [0u64; 3];
    let mut cells = 0u64;
    let shaded =
        |sample: u16, gain: u32| u64::from(sample.saturating_sub(black_level)) * u64::from(gain);
    frame.cell_rows(row_step, |row, top, bottom| {
        gains.row(row, &mut top_gains);
        gains.row(row + 1, &mut bottom_gains);
        for i in (0..frame.width).step_by(2) {
            sums[0] += shaded(top[i], top_gains[i]);
            sums[1] += shaded(top[i + 1], top_gains[i + 1]) + shaded(bottom[i], bottom_gains[i]);
            sums[2] += shaded(bottom[i + 1], bottom_gains[i + 1]);
            cells += 1;
        }
    });
    let samples = cells.max(1) as f64 * f64::from(1u32 << GAIN_SHIFT);
    [
        sums[0] as f64 / samples,
        sums[1] as f64 / 2.0 / samples,
        sums[2] as f64 / samples,
    ]
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

/// Writes rows of pixels' linear red, green and blue into an image: through
/// the colour matrix, then the contrast table.
struct Renderer<'a> {
    matrix: [[i32; 3]; 3],
    contrast: &'a ContrastTable,
    image: Image<'a>,
    entries: &'a mut [u16],
}

impl<'a> Renderer<'a> {
    /// The renderer of `colour` into `image`, rows of `width` pixels,
    /// through `entries`.
    fn new(
        colour: &Colour<'a>,
        image: Image<'a>,
        width: usize,
        entries: &'a mut Vec<u16>,
    ) -> Renderer<'a> {
        entries.resize(width * 3, 0);
        Renderer {
            matrix: fixed_matrix(colour.matrix),
            contrast: colour.contrast,
            image,
            entries,
        }
    }

    /// Takes row `y` of pixels' linear red, green and blue, `rgb`.
    fn row(&mut self, y: usize, rgb: &[u16]) {
        apply_matrix(&self.matrix, rgb, self.entries, entry);
        write_row(self.contrast, &mut self.image, y, self.entries);
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

/// Writes row `y` of `image`: the outputs of the contrast table's `entries`.
fn write_row(contrast: &ContrastTable, image: &mut Image, y: usize, entries: &[u16]) {
    image.write(y, |out| {
        for (&entry, out) in entries.iter().zip(out) {
            *out = contrast.output(entry);
        }
    });
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
        let colour = Colour {
            black_level: BLACK,
            shading: &shading,
            white_balance: gains,
            matrix: TUNING.colour_matrix(kelvin),
            contrast: &contrast,
        };

        assert!((gains.red / light.red - 1.0).abs() < 0.005, "{gains:?}");
        assert!((gains.blue / light.blue - 1.0).abs() < 0.005, "{gains:?}");
        for rgb in [full(&frame, &colour, false), half(&frame, &colour, false)] {
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
        let colour = Colour {
            black_level: 0,
            shading: &shading,
            white_balance: UNITY,
            matrix: IDENTITY,
            contrast: &contrast,
        };
        assert_eq!(
            shaded_channel_means(&frame, 0, &shading, 1),
            [2000.0, 1000.0, 1500.0]
        );
        // 2000, 1000 and 1500 of 4095.
        assert_eq!(full(&frame, &colour, false), [125, 62, 93].repeat(32));
        assert_eq!(half(&frame, &colour, false), [125, 62, 93].repeat(8));
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
        let colour = Colour {
            black_level: BLACK,
            shading: &shading,
            white_balance: Gains {
                red: 2.2,
                blue: 1.6,
            },
            matrix: TUNING.colour_matrix(3000.0),
            contrast: &contrast,
        };
        let turned =
            |rgb: Vec<u8>| -> Vec<u8> { rgb.chunks_exact(3).rev().flatten().copied().collect() };
        assert_eq!(
            full(&frame, &colour, true),
            turned(full(&frame, &colour, false))
        );
        assert_eq!(
            half(&frame, &colour, true),
            turned(half(&frame, &colour, false))
        );
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
        };
        let (frame, other) = (frame(&raw, 8, 6), frame(&other_raw, 4, 4));
        let mut buffers = Buffers::default();
        rgb_full(&frame, &colour, false, &mut buffers);
        assert_eq!(
            rgb_half(&other, &colour, true, &mut buffers),
            half(&other, &colour, true)
        );
        assert_eq!(
            rgb_full(&other, &colour, false, &mut buffers),
            full(&other, &colour, false)
        );
        assert_eq!(
            rgb_full(&frame, &colour, false, &mut buffers),
            full(&frame, &colour, false)
        );
    }

    fn full(frame: &RawFrame, colour: &Colour, rotate_180: bool) -> Vec<u8> {
        rgb_full(frame, colour, rotate_180, &mut Buffers::default()).to_vec()
    }

    fn half(frame: &RawFrame, colour: &Colour, rotate_180: bool) -> Vec<u8> {
        rgb_half(frame, colour, rotate_180, &mut Buffers::default()).to_vec()
    }
}
