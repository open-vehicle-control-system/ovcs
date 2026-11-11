//! A single camera's frame converted a band of rows at a time, and what is
//! measured of it on the way.

use std::ops::Range;

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
}

/// A frame converted: 8-bit red, green and blue per pixel, row-major, and
/// what `Conversion` asked to measure of it.
pub struct Developed<'a> {
    pub rgb: &'a [u8],
    pub channel_means: Option<[f64; 3]>,
    pub green_mean: Option<f64>,
}

impl<'a> Developed<'a> {
    /// `rgb` with the means of `sums` that `conversion` asked for, each
    /// channel sum taken as `scale` times its samples' values.
    pub fn new(rgb: &'a [u8], sums: Sums, conversion: &Conversion, scale: f64) -> Developed<'a> {
        let cells = sums.cells.max(1) as f64;
        let samples = cells * scale;
        Developed {
            rgb,
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

/// Converts an image of rows of `width` pixels into `rgb`, turned by 180
/// degrees with `rotate_180`, its rows grouped by `cell`:
/// `convert(cell_rows, image, scratch)` writes the rows of the groups
/// `cell_rows` into `image` through `scratch` and returns what it measured
/// of them. Returns the sums measured.
pub fn convert<S: Default>(
    rgb: &mut [u8],
    width: usize,
    cell: usize,
    rotate_180: bool,
    scratch: &mut Vec<S>,
    convert: impl Fn(Range<usize>, Image, &mut S) -> Sums,
) -> Sums {
    let height = rgb.len() / (width * 3).max(1);
    if scratch.is_empty() {
        scratch.push(S::default());
    }
    convert(
        0..height / cell,
        Image::band(rgb, width, 0..height, rotate_180),
        &mut scratch[0],
    )
}
