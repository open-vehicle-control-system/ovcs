//! A single camera's frame converted in bands of rows, each on a thread of
//! its own, and what is measured of it on the way.

use std::ops::Range;
use std::panic;

use crate::arguments::Output;
use crate::bayer::Image;

/// How a frame is converted: at which size, which way up, and what is
/// measured of it besides its image.
#[derive(Clone, Copy, Debug)]
pub struct Conversion {
    pub output: Output,
    /// Turns the image by 180 degrees, for a sensor mounted upside down.
    pub rotate_180: bool,
    /// Measures the channel means white balance takes.
    pub channel_means: bool,
    /// Measures the green auto exposure steers.
    pub green_mean: bool,
    /// Both measure every this many rows of RGGB cells.
    pub row_step: usize,
    /// The bands of rows converted at once, each on a thread of its own.
    pub threads: usize,
}

/// What `Conversion` asked to measure of a frame converted.
pub struct Measures {
    pub channel_means: Option<[f64; 3]>,
    pub green_mean: Option<f64>,
}

impl Measures {
    /// The means of `sums` that `conversion` asked for, each channel sum
    /// taken as `scale` times its samples' values.
    pub fn new(sums: Sums, conversion: &Conversion, scale: f64) -> Measures {
        let cells = sums.cells.max(1) as f64;
        let samples = cells * scale;
        Measures {
            channel_means: conversion.channel_means.then(|| {
                [
                    sums.channels[0] as f64 / samples,
                    sums.channels[1] as f64 / 2.0 / samples,
                    sums.channels[2] as f64 / samples,
                ]
            }),
            green_mean: conversion.green_mean.then(|| sums.green as f64 / cells),
        }
    }
}

/// Sums over the RGGB cells a band measures.
#[derive(Clone, Copy, Debug, Default)]
pub struct Sums {
    pub cells: u64,
    /// Their red, both greens, and blue.
    pub channels: [u64; 3],
    /// Their green as auto exposure measures it.
    pub green: u64,
}

impl Sums {
    fn add(self, other: Sums) -> Sums {
        Sums {
            cells: self.cells + other.cells,
            channels: std::array::from_fn(|i| self.channels[i] + other.channels[i]),
            green: self.green + other.green,
        }
    }
}

/// Converts an image of rows of `width` pixels into `rgb`, turned by 180
/// degrees with `rotate_180`, its rows grouped by `cell`, in up to
/// `threads` bands of groups (`split`): `convert(cell_rows, image,
/// scratch)` writes the rows of the groups `cell_rows` into `image`, which
/// holds those rows of `rgb`, through a `scratch` of the band's own, and
/// returns what it measured of them. Each band but the last runs on a
/// thread of its own, the last on the calling one. Returns the sums
/// measured, added up.
pub fn convert<S: Default + Send>(
    rgb: &mut [u8],
    width: usize,
    cell: usize,
    rotate_180: bool,
    threads: usize,
    scratch: &mut Vec<S>,
    convert: impl Fn(Range<usize>, Image, &mut S) -> Sums + Sync,
) -> Sums {
    let height = rgb.len() / (width * 3).max(1);
    let bands = split(height / cell, threads);
    if scratch.len() < bands.len() {
        scratch.resize_with(bands.len(), S::default);
    }
    let image = |part, cells: &Range<usize>| {
        Image::band(
            part,
            width,
            cell * cells.start..cell * cells.end,
            rotate_180,
        )
    };
    if let [cells] = &bands[..] {
        return convert(cells.clone(), image(rgb, cells), &mut scratch[0]);
    }
    let parts = parts(rgb, width * 3 * cell, &bands, rotate_180);
    let convert = &convert;
    std::thread::scope(|scope| {
        let mut jobs = bands.iter().zip(parts).zip(scratch.iter_mut());
        let ((last_cells, last_part), last_scratch) = jobs.next_back().expect("a band");
        let running: Vec<_> = jobs
            .map(|((cells, part), scratch)| {
                scope.spawn(move || convert(cells.clone(), image(part, cells), scratch))
            })
            .collect();
        let last = convert(
            last_cells.clone(),
            image(last_part, last_cells),
            last_scratch,
        );
        running.into_iter().fold(last, |sums, band| {
            sums.add(
                band.join()
                    .unwrap_or_else(|panic| panic::resume_unwind(panic)),
            )
        })
    })
}

/// `cell_rows` rows of cells split into up to `count` bands, top to bottom,
/// none empty but for an image without rows, their sizes at most one apart.
fn split(cell_rows: usize, count: usize) -> Vec<Range<usize>> {
    let count = count.clamp(1, cell_rows.max(1));
    (0..count)
        .map(|band| cell_rows * band / count..cell_rows * (band + 1) / count)
        .collect()
}

/// The part of `rgb` each band of `bands`, rows of `row_bytes` bytes each,
/// fills: in their order, or with `rotate_180` from the end, where the
/// turned image has them.
fn parts<'a>(
    mut rgb: &'a mut [u8],
    row_bytes: usize,
    bands: &[Range<usize>],
    rotate_180: bool,
) -> Vec<&'a mut [u8]> {
    let mut parts = Vec::with_capacity(bands.len());
    let mut take = |rows: usize| {
        let (part, rest) = std::mem::take(&mut rgb).split_at_mut(rows * row_bytes);
        rgb = rest;
        parts.push(part);
    };
    if rotate_180 {
        bands.iter().rev().for_each(|band| take(band.len()));
        parts.reverse();
    } else {
        bands.iter().for_each(|band| take(band.len()));
    }
    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bands_cover_the_rows_of_cells_in_order_their_sizes_at_most_one_apart() {
        assert_eq!(split(760, 3), [0..253, 253..506, 506..760]);
        assert_eq!(split(25, 4), [0..6, 6..12, 12..18, 18..25]);
        assert_eq!(split(10, 1), vec![0..10]);
    }

    #[test]
    fn there_are_no_more_bands_than_rows_of_cells() {
        assert_eq!(split(3, 4), [0..1, 1..2, 2..3]);
        assert_eq!(split(0, 3), vec![0..0]);
    }

    // Each row of an image 2 pixels wide, its rows grouped by `cell`, as
    // its index, written in bands on `threads` threads.
    fn row_indices(rows: usize, cell: usize, rotate_180: bool, threads: usize) -> (Vec<u8>, u64) {
        let mut rgb = vec![0; rows * 2 * 3];
        let mut scratch: Vec<()> = Vec::new();
        let sums = convert(
            &mut rgb,
            2,
            cell,
            rotate_180,
            threads,
            &mut scratch,
            |cells, mut image, _| {
                for y in cell * cells.start..cell * cells.end {
                    image.write(y, |out| out.fill(y as u8));
                }
                Sums {
                    cells: cells.len() as u64,
                    ..Sums::default()
                }
            },
        );
        (rgb, sums.cells)
    }

    #[test]
    fn each_band_writes_its_own_rows_where_the_image_has_them() {
        for (rows, cell) in [(7, 1), (10, 2), (2, 2)] {
            for rotate_180 in [false, true] {
                let mut expected: Vec<u8> = (0..rows).flat_map(|y| [y as u8; 6]).collect();
                if rotate_180 {
                    expected.reverse();
                }
                for threads in 1..=5 {
                    assert_eq!(
                        row_indices(rows, cell, rotate_180, threads),
                        (expected.clone(), (rows / cell) as u64),
                        "{rows} rows of {cell}, rotated {rotate_180}, {threads} threads"
                    );
                }
            }
        }
    }
}
