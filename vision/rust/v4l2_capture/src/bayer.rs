//! Raw Bayer to grey or to colour.

use std::ops::Range;

use crate::arguments::Output;
use crate::bands::{self, Conversion, Images, Measures, Sums};
use crate::scale;
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

    /// The samples stored together: a row's width is a multiple of it.
    pub fn samples_per_group(self) -> usize {
        match self {
            Layout::Unpacked16 => 1,
            Layout::Packed10 => 4,
            Layout::Packed12 => 2,
        }
    }

    /// The bits of each sample.
    pub fn sample_bits(self) -> u32 {
        match self {
            Layout::Unpacked16 | Layout::Packed10 => 10,
            Layout::Packed12 => 12,
        }
    }
}

/// The samples of one row, `out.len()` of them: a multiple of 4 for `Packed10`, of 2 for `Packed12`.
fn samples(row: &[u8], layout: Layout, out: &mut [u16]) {
    match layout {
        Layout::Unpacked16 => {
            // The container holds more than the sample's depth, which the colour path's
            // fixed point counts on.
            let full_scale = (1u16 << layout.sample_bits()) - 1;
            for (sample, bytes) in out.iter_mut().zip(row.chunks_exact(2)) {
                *sample = u16::from_le_bytes([bytes[0], bytes[1]]).min(full_scale);
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

/// The samples of a row of RGGB cells' two rows, kept from one frame to the next.
pub(crate) type CellRows = [Vec<u16>; 2];

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
    /// The frame's rows of RGGB cells.
    pub(crate) fn cell_row_count(&self) -> usize {
        self.height / 2
    }

    /// Calls `cell_row` with the index of the top row of each row of RGGB
    /// cells in `cell_rows` whose index is a multiple of `step`, then its top
    /// row's samples and its bottom row's, unpacked into `rows`.
    pub(crate) fn cell_rows(
        &self,
        cell_rows: Range<usize>,
        step: usize,
        [top, bottom]: &mut CellRows,
        mut cell_row: impl FnMut(usize, &[u16], &[u16]),
    ) {
        let row_bytes = self.layout.row_bytes(self.width);
        top.resize(self.width, 0);
        bottom.resize(self.width, 0);
        let rows = &self.raw[..self.row_stride * self.height];
        let step = step.max(1);
        let end = cell_rows.end.min(self.cell_row_count());
        for cell_row_index in (cell_rows.start.next_multiple_of(step)..end).step_by(step) {
            let top_row = &rows[2 * cell_row_index * self.row_stride..];
            let bottom_row = &top_row[self.row_stride..];
            samples(&top_row[..row_bytes], self.layout, top);
            samples(&bottom_row[..row_bytes], self.layout, bottom);
            cell_row(2 * cell_row_index, top, bottom);
        }
    }
}

/// What the colour path of a sensor without a tuning keeps from one frame
/// to the next: the rows each band of it demosaics.
#[derive(Default)]
pub struct Buffers {
    bands: Vec<DemosaicRows<u8>>,
}

/// `frame` into `images`' `rgb`, 8-bit red, green and blue per pixel,
/// row-major, through `buffers`, at the size of `conversion.output`, each
/// sample through `tone`, red and blue scaled by `gains` first. At its own
/// size, each pixel keeps its own sample and takes each missing colour as
/// the mean of its nearest samples of that colour, the 4 axial ones for
/// green, the 2 axial or 4 diagonal ones for red and blue; at the image's
/// edges the nearest sample of a colour stands in for the neighbour beyond
/// it. At half size, each 2x2 RGGB cell is one pixel: red, the mean of both
/// greens, and blue. Measures what `conversion` asks for (`measure`).
///
/// At its own size, white balance by `gains`, then the tone, then
/// interpolation: one lookup per sample instead of three per pixel,
/// invisible between neighbours.
pub fn develop(
    frame: &RawFrame,
    tone: &Tone,
    gains: Gains,
    conversion: &Conversion,
    images: Images,
    Buffers { bands }: &mut Buffers,
) -> Measures {
    let rotate_180 = conversion.rotate_180;
    let sums = match conversion.output {
        Output::Full => {
            let scaled_table = |gain: f64| -> Vec<u8> {
                let gain_q12 = q12(gain);
                (0..tone.table.len())
                    .map(|sample| tone.scaled(sample as u16, gain_q12))
                    .collect()
            };
            let (red, blue) = (scaled_table(gains.red), scaled_table(gains.blue));
            let tables = ChannelTables {
                red: &red,
                green: &tone.table,
                blue: &blue,
            };
            images
                .rgb
                .resize(frame.width * frame.cell_row_count() * 2 * 3, 0);
            bands::convert(
                images,
                frame.width,
                2,
                rotate_180,
                conversion.threads,
                bands,
                |cells, image, demosaic| {
                    let sums = measure(frame, tone, conversion, cells.clone(), &mut demosaic.cells);
                    full_band(frame, &tables, cells, image, demosaic);
                    sums
                },
            )
        }
        Output::Half => {
            let gains_q12 = (q12(gains.red), q12(gains.blue));
            images
                .rgb
                .resize(frame.width / 2 * frame.cell_row_count() * 3, 0);
            bands::convert(
                images,
                frame.width / 2,
                1,
                rotate_180,
                conversion.threads,
                bands,
                |cells, image, demosaic| {
                    let rows = &mut demosaic.cells;
                    let sums = measure(frame, tone, conversion, cells.clone(), rows);
                    half_band(frame, tone, gains_q12, cells, image, rows);
                    sums
                },
            )
        }
    };
    Measures::new(sums, conversion, 1.0)
}

/// Writes the rows of RGGB cells `cells` of `frame` at its own size into
/// `image`, each sample through `tables`, through `demosaic`.
fn full_band(
    frame: &RawFrame,
    tables: &ChannelTables,
    cells: Range<usize>,
    mut image: Image,
    demosaic: &mut DemosaicRows<u8>,
) {
    demosaic_full(
        frame,
        demosaic,
        2 * cells.start..2 * cells.end,
        |row, samples, toned: &mut [u8]| tables.tone_row(samples, row.is_multiple_of(2), toned),
        |y, values| image.write(y, |out| out.copy_from_slice(values)),
    );
}

/// Writes the rows of RGGB cells `cells` of `frame` into `image`, each cell
/// one pixel, through `tone`, red and blue scaled by `gains_q12`, red's and
/// blue's gains in 1/4096ths, first.
fn half_band(
    frame: &RawFrame,
    tone: &Tone,
    (red_q12, blue_q12): (u32, u32),
    cells: Range<usize>,
    mut image: Image,
    rows: &mut CellRows,
) {
    frame.cell_rows(cells, 1, rows, |row, top, bottom| {
        image.write(row / 2, |out| {
            for ((top_pair, bottom_pair), pixel) in top
                .chunks_exact(2)
                .zip(bottom.chunks_exact(2))
                .zip(out.chunks_exact_mut(3))
            {
                let green = (u32::from(top_pair[1]) + u32::from(bottom_pair[0])) / 2;
                pixel[0] = tone.scaled(top_pair[0], red_q12);
                pixel[1] = tone.grey(green as u16);
                pixel[2] = tone.scaled(bottom_pair[1], blue_q12);
            }
        });
    });
}

/// Rows of an 8-bit red, green and blue image written a row at a time, top
/// to bottom, turned by 180 degrees with `rotate_180` for a sensor mounted
/// upside down, and with `averaged` each 2x2 block of it averaged.
pub(crate) struct Image<'a> {
    rgb: &'a mut [u8],
    averaged: Option<&'a mut [u8]>,
    row_bytes: usize,
    rows: Range<usize>,
    rotate_180: bool,
}

impl<'a> Image<'a> {
    /// Rows `rows` of an image of rows of `width` pixels, held in `rgb`
    /// where the image has them: in their order, or with `rotate_180` in
    /// reverse; with `averaged`, the rows of its 2x2 average they make, the
    /// band starting on an even row.
    pub(crate) fn band(
        rgb: &'a mut [u8],
        averaged: Option<&'a mut [u8]>,
        width: usize,
        rows: Range<usize>,
        rotate_180: bool,
    ) -> Image<'a> {
        Image {
            rgb,
            averaged,
            row_bytes: width * 3,
            rows,
            rotate_180,
        }
    }

    /// Writes row `y` with `write`.
    pub(crate) fn write(&mut self, y: usize, write: impl FnOnce(&mut [u8])) {
        let row_bytes = self.row_bytes;
        let target = if self.rotate_180 {
            self.rows.end - 1 - y
        } else {
            y - self.rows.start
        };
        let out = &mut self.rgb[target * row_bytes..(target + 1) * row_bytes];
        write(out);
        if self.rotate_180 {
            // Reversing the bytes reverses the pixels but turns each into
            // blue, green, red; the swap restores red, green, blue.
            out.reverse();
            for pixel in out.chunks_exact_mut(3) {
                pixel.swap(0, 2);
            }
        }
        if let (Some(averaged), 1) = (&mut self.averaged, y % 2) {
            // Averaged while the pair of rows is in cache rather than in a
            // pass over the whole image (`scale`, the general path).
            let pair = if self.rotate_180 { target } else { target - 1 };
            let averaged_bytes = row_bytes / 2;
            scale::average_rows(
                &self.rgb[pair * row_bytes..(pair + 2) * row_bytes],
                row_bytes / 3,
                (2, 2),
                &mut averaged[pair / 2 * averaged_bytes..(pair / 2 + 1) * averaged_bytes],
            );
        }
    }
}

/// The rows `demosaic_full` works on, kept from one frame to the next.
pub(crate) struct DemosaicRows<V> {
    cells: CellRows,
    samples: Vec<u16>,
    developed: [Vec<V>; 3],
    interpolated: Vec<V>,
}

impl<V> Default for DemosaicRows<V> {
    fn default() -> DemosaicRows<V> {
        DemosaicRows {
            cells: CellRows::default(),
            samples: Vec::new(),
            developed: std::array::from_fn(|_| Vec::new()),
            interpolated: Vec::new(),
        }
    }
}

/// A value demosaicing interpolates.
pub(crate) trait Sample: Copy + Default + Into<u32> {
    /// The value of a mean of values of this type.
    fn from_mean(mean: u32) -> Self;
}

impl Sample for u8 {
    fn from_mean(mean: u32) -> u8 {
        mean as u8
    }
}

impl Sample for u16 {
    fn from_mean(mean: u32) -> u16 {
        mean as u16
    }
}

/// Demosaics rows `rows` of `frame` at its own size as `develop` does, in
/// `buffers`, on the values `develop_row(row, samples, values)` gives the
/// samples of those rows and of the rows next to them, and hands each row of
/// pixels' red, green and blue values, top to bottom, to `pixel_row(y,
/// values)`.
pub(crate) fn demosaic_full<V: Sample>(
    frame: &RawFrame,
    buffers: &mut DemosaicRows<V>,
    rows: Range<usize>,
    mut develop_row: impl FnMut(usize, &[u16], &mut [V]),
    mut pixel_row: impl FnMut(usize, &[V]),
) {
    let (width, height) = (frame.width, frame.height);
    let rows = rows.start..rows.end.min(height);
    if width < 2 || height < 2 || rows.is_empty() {
        return;
    }
    let row_bytes = frame.layout.row_bytes(width);
    let DemosaicRows {
        samples: row_samples,
        developed,
        interpolated,
        ..
    } = buffers;
    row_samples.resize(width, 0);
    // Rows y - 1, y and y + 1, developed, at index row % 3, each with the
    // nearest value of the same colour beyond each end.
    for values in developed.iter_mut() {
        values.resize(width + 2, V::default());
    }
    interpolated.resize(width * 3, V::default());
    let mut develop = |row: usize, developed: &mut [Vec<V>; 3]| {
        let start = row * frame.row_stride;
        samples(
            &frame.raw[start..start + row_bytes],
            frame.layout,
            row_samples,
        );
        let values = &mut developed[row % 3];
        develop_row(row, row_samples, &mut values[1..=width]);
        values[0] = values[2];
        values[width + 1] = values[width - 1];
    };
    // From the row above the first, or from the frame's top row.
    let first = rows.start.max(1) - 1;
    develop(first, developed);
    develop(first + 1, developed);
    for y in rows {
        if y >= 1 && y + 1 < height {
            develop(y + 1, developed);
        }
        let up = if y == 0 { 1 } else { y - 1 };
        let down = if y + 1 == height { y - 1 } else { y + 1 };
        let rows = (
            &developed[up % 3][..],
            &developed[y % 3][..],
            &developed[down % 3][..],
        );
        if y.is_multiple_of(2) {
            interpolate_row::<true, V>(rows, interpolated);
        } else {
            interpolate_row::<false, V>(rows, interpolated);
        }
        pixel_row(y, interpolated);
    }
}

/// Each channel's 8-bit value of a raw sample.
struct ChannelTables<'a> {
    red: &'a [u8],
    green: &'a [u8],
    blue: &'a [u8],
}

impl ChannelTables<'_> {
    /// Tones a row of samples into `toned`, through red and green on a row
    /// of red cells, green and blue otherwise.
    fn tone_row(&self, row: &[u16], red_row: bool, toned: &mut [u8]) {
        let (even, odd) = if red_row {
            (self.red, self.green)
        } else {
            (self.green, self.blue)
        };
        let last = even.len() - 1;
        for (pair, out) in row.chunks_exact(2).zip(toned.chunks_exact_mut(2)) {
            out[0] = even[usize::from(pair[0]).min(last)];
            out[1] = odd[usize::from(pair[1]).min(last)];
        }
    }
}

/// Interpolates one row of pixels, red, green and blue each, from the rows
/// of values above it, its own and below it, each holding one value beyond
/// each edge: a row of red and green samples when `RED_ROW`, of green and
/// blue otherwise.
fn interpolate_row<const RED_ROW: bool, V: Sample>(
    (up, centre, down): (&[V], &[V], &[V]),
    out: &mut [V],
) {
    let (colour, other) = if RED_ROW { (0, 2) } else { (2, 0) };
    let at = |row: &[V], i: usize| -> u32 { row[i].into() };
    let mean2 = |a: u32, b: u32| V::from_mean((a + b + 1) >> 1);
    let mean4 = |a: u32, b: u32, c: u32, d: u32| V::from_mean((a + b + c + d + 2) >> 2);
    let colour_site = |i: usize, out: &mut [V]| {
        out[colour] = centre[i];
        out[1] = mean4(at(centre, i - 1), at(centre, i + 1), at(up, i), at(down, i));
        out[other] = mean4(
            at(up, i - 1),
            at(up, i + 1),
            at(down, i - 1),
            at(down, i + 1),
        );
    };
    let green_site = |i: usize, out: &mut [V]| {
        out[1] = centre[i];
        out[colour] = mean2(at(centre, i - 1), at(centre, i + 1));
        out[other] = mean2(at(up, i), at(down, i));
    };
    for (pair, pixels) in out.chunks_exact_mut(6).enumerate() {
        let i = 2 * pair + 1;
        let (first, second) = pixels.split_at_mut(3);
        if RED_ROW {
            colour_site(i, first);
            green_site(i + 1, second);
        } else {
            green_site(i, first);
            colour_site(i + 1, second);
        }
    }
}

fn q12(gain: f64) -> u32 {
    (gain * 4096.0).round() as u32
}

/// What `conversion` asks to measure of every `conversion.row_step`-th row
/// of RGGB cells of `frame` within `cells`: for auto exposure, each cell's
/// two greens averaged through `tone`, as the half-size image has them; for
/// white balance, each cell's red, greens and blue above `tone`'s black
/// level.
fn measure(
    frame: &RawFrame,
    tone: &Tone,
    conversion: &Conversion,
    cells: Range<usize>,
    rows: &mut CellRows,
) -> Sums {
    let signal = |sample: u16| u64::from(sample.saturating_sub(tone.black_level));
    Sums::measured(frame, conversion, cells, rows, |_, top, bottom, sums| {
        for (top_pair, bottom_pair) in top.chunks_exact(2).zip(bottom.chunks_exact(2)) {
            if conversion.green_mean {
                let green = (u32::from(top_pair[1]) + u32::from(bottom_pair[0])) / 2;
                sums.green += u64::from(tone.grey(green as u16));
            }
            if conversion.channel_means {
                sums.channels[0] += signal(top_pair[0]);
                sums.channels[1] += signal(top_pair[1]) + signal(bottom_pair[0]);
                sums.channels[2] += signal(bottom_pair[1]);
            }
        }
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn little_endian_samples(samples: &[u16]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    #[test]
    fn a_row_holds_whole_groups_of_its_layouts_samples() {
        for (layout, group, bytes) in [
            (Layout::Unpacked16, 1, 2),
            (Layout::Packed10, 4, 5),
            (Layout::Packed12, 2, 3),
        ] {
            assert_eq!(layout.samples_per_group(), group);
            assert_eq!(layout.row_bytes(group), bytes);
        }
    }

    #[test]
    fn an_unpacked_sample_above_its_depth_is_full_scale() {
        let mut row = [0u16; 3];
        let raw = little_endian_samples(&[1023, 1024, 0xffff]);
        samples(&raw, Layout::Unpacked16, &mut row);
        assert_eq!(row, [1023, 1023, 1023]);
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
    pub(crate) fn packed12(samples: &[u16]) -> Vec<u8> {
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

    fn conversion(output: Output, rotate_180: bool) -> Conversion {
        Conversion {
            output,
            rotate_180,
            channel_means: true,
            green_mean: true,
            row_step: 1,
            threads: 1,
        }
    }

    fn rgb_half(frame: &RawFrame, tone: &Tone, gains: Gains, rotate_180: bool) -> Vec<u8> {
        let conversion = conversion(Output::Half, rotate_180);
        let mut rgb = Vec::new();
        develop(
            frame,
            tone,
            gains,
            &conversion,
            Images {
                rgb: &mut rgb,
                averaged: None,
            },
            &mut Buffers::default(),
        );
        rgb
    }

    fn rgb_full(frame: &RawFrame, tone: &Tone, gains: Gains, rotate_180: bool) -> Vec<u8> {
        let conversion = conversion(Output::Full, rotate_180);
        let mut rgb = Vec::new();
        develop(
            frame,
            tone,
            gains,
            &conversion,
            Images {
                rgb: &mut rgb,
                averaged: None,
            },
            &mut Buffers::default(),
        );
        rgb
    }

    // The mean green of the half-size image's pixels over every
    // `row_step`-th row of RGGB cells.
    fn toned_green_mean(frame: &RawFrame, tone: &Tone, row_step: usize) -> f64 {
        let conversion = Conversion {
            row_step,
            ..conversion(Output::Half, false)
        };
        develop(
            frame,
            tone,
            UNITY,
            &conversion,
            Images {
                rgb: &mut Vec::new(),
                averaged: None,
            },
            &mut Buffers::default(),
        )
        .green_mean
        .unwrap()
    }

    // The mean red, green and blue above `black_level` over every
    // `row_step`-th row of RGGB cells.
    fn channel_means(frame: &RawFrame, black_level: u16, row_step: usize) -> [f64; 3] {
        let tone = Tone::with_sample_bits(black_level, 1.0, frame.layout.sample_bits());
        let conversion = Conversion {
            row_step,
            ..conversion(Output::Half, false)
        };
        develop(
            frame,
            &tone,
            UNITY,
            &conversion,
            Images {
                rgb: &mut Vec::new(),
                averaged: None,
            },
            &mut Buffers::default(),
        )
        .channel_means
        .unwrap()
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

    // 8-bit samples through an 8-bit linear tone come out unchanged.
    fn identity_tone() -> Tone {
        Tone::with_sample_bits(0, 1.0, 8)
    }

    // Rows of `samples`, `width` each, packed as 12-bit and padded with 0xff
    // to `row_stride` bytes.
    pub(crate) fn padded_packed12(samples: &[u16], width: usize, row_stride: usize) -> Vec<u8> {
        samples
            .chunks_exact(width)
            .flat_map(|row| {
                let mut bytes = packed12(row);
                bytes.resize(row_stride, 0xff);
                bytes
            })
            .collect()
    }

    // Four rows of RGGB cells, each sample distinct from its neighbours.
    const FOUR_BY_FOUR: [u16; 16] = [
        200, 10, 160, 30, //
        50, 4, 70, 8, //
        120, 90, 80, 110, //
        130, 12, 150, 16,
    ];

    #[test]
    fn full_output_interpolates_each_pixels_missing_colours_from_its_neighbours() {
        let raw = padded_packed12(&FOUR_BY_FOUR, 4, 8);
        let frame = RawFrame {
            raw: &raw,
            width: 4,
            height: 4,
            row_stride: 8,
            layout: Layout::Packed12,
        };
        #[rustfmt::skip]
        let expected = [
            200, 30, 4,    180, 10, 4,    160, 45, 6,    160, 30, 8,
            160, 50, 4,    140, 55, 4,    120, 70, 6,    120, 70, 8,
            120, 90, 8,    100, 90, 8,    80, 105, 10,   80, 110, 12,
            120, 130, 12,  100, 115, 12,  80, 150, 14,   80, 130, 16,
        ];
        assert_eq!(rgb_full(&frame, &identity_tone(), UNITY, false), expected);
    }

    #[test]
    fn a_uniform_colour_stays_uniform_at_full_size() {
        let cells = [1000, 2000, 2000, 3000];
        let samples: Vec<u16> = (0..4)
            .flat_map(|row| (0..6).map(move |column| cells[(row % 2) * 2 + column % 2]))
            .collect();
        let raw = padded_packed12(&samples, 6, 12);
        let frame = RawFrame {
            raw: &raw,
            width: 6,
            height: 4,
            row_stride: 12,
            layout: Layout::Packed12,
        };
        let tone = linear_tone();
        let pixel = [tone.grey(1000), tone.grey(2000), tone.grey(3000)];
        assert_eq!(rgb_full(&frame, &tone, UNITY, false), pixel.repeat(24));
    }

    #[test]
    fn full_output_scales_red_and_blue_by_the_white_balance_gains() {
        let raw = padded_packed12(&[100; 16], 4, 6);
        let frame = RawFrame {
            raw: &raw,
            width: 4,
            height: 4,
            row_stride: 6,
            layout: Layout::Packed12,
        };
        let gains = Gains {
            red: 2.0,
            blue: 0.5,
        };
        assert_eq!(
            rgb_full(&frame, &identity_tone(), gains, false),
            [200, 100, 50].repeat(16)
        );
    }

    #[test]
    fn a_rotated_full_image_reverses_the_pixels_each_red_green_blue() {
        let raw = padded_packed12(&FOUR_BY_FOUR, 4, 6);
        let frame = RawFrame {
            raw: &raw,
            width: 4,
            height: 4,
            row_stride: 6,
            layout: Layout::Packed12,
        };
        let upright = rgb_full(&frame, &identity_tone(), UNITY, false);
        let reversed: Vec<u8> = upright.chunks_exact(3).rev().flatten().copied().collect();
        assert_eq!(rgb_full(&frame, &identity_tone(), UNITY, true), reversed);
    }

    #[test]
    fn the_toned_green_mean_is_the_half_outputs_mean_green() {
        let raw = padded_packed12(&FOUR_BY_FOUR, 4, 6);
        let frame = RawFrame {
            raw: &raw,
            width: 4,
            height: 4,
            row_stride: 6,
            layout: Layout::Packed12,
        };
        let tone = Tone::with_sample_bits(0, 2.2, 8);
        let half = rgb_half(&frame, &tone, UNITY, false);
        let greens: Vec<f64> = half
            .chunks_exact(3)
            .map(|pixel| f64::from(pixel[1]))
            .collect();
        let mean = greens.iter().sum::<f64>() / greens.len() as f64;
        assert_eq!(toned_green_mean(&frame, &tone, 1), mean);
        assert_eq!(
            toned_green_mean(&frame, &tone, 2),
            (greens[0] + greens[1]) / 2.0
        );
    }

    #[test]
    fn padded_12_bit_rows_give_the_same_channel_means() {
        let samples = [300, 100, 300, 100, 300, 50, 300, 100];
        let packed = padded_packed12(&samples, 4, 6);
        let padded = padded_packed12(&samples, 4, 10);
        let means = |raw: &[u8], row_stride| {
            let frame = RawFrame {
                raw,
                width: 4,
                height: 2,
                row_stride,
                layout: Layout::Packed12,
            };
            channel_means(&frame, 0, 1)
        };
        assert_eq!(means(&padded, 10), means(&packed, 6));
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
