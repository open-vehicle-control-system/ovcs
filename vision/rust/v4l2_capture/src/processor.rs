//! What makes a camera output from the sensor's raw frame: a processor.
//! `Cpu` is the software conversion; an output scaled from another one is
//! made after the processors (`scale`), but for the 2x2 average of a `Cpu`
//! output, which it makes as it converts.

use crate::arguments::Output;
use crate::bands::{Conversion, Images, Measures};
use crate::bayer::{self, RawFrame, Tone};
use crate::colour::{self, Colour, ContrastTable};
use crate::sensor::SensorModel;
use crate::settings::ColourSettings;
use crate::tuning::Tuning;
use crate::white_balance::Gains;

/// White balance and auto exposure measure every this many rows of RGGB
/// cells, the same cells whatever the output's size.
pub const MEASURED_ROW_STEP: usize = 4;

/// Makes an output from each raw frame.
pub trait Processor: Send {
    /// `frame` as `development` says, into `images`, with what it asks to
    /// measure. `images` holds an averaged image only when the processor
    /// `averages_2x2`.
    fn develop(&mut self, frame: &RawFrame, development: &Development, images: Images) -> Measures;

    /// Whether `develop` makes the 2x2 average of its image too.
    fn averages_2x2(&self) -> bool {
        false
    }
}

/// How a frame is developed, as the settings stand when it comes.
pub struct Development<'a> {
    pub settings: &'a ColourSettings,
    /// The white balance gains in force.
    pub gains: Gains,
    /// The tone of a sensor without a tuning.
    pub tone: &'a Tone,
    /// Measures the channel means white balance takes.
    pub channel_means: bool,
    /// Measures the green auto exposure steers.
    pub green_mean: bool,
    /// The threads the frame is converted on.
    pub threads: usize,
}

/// The software conversion at the size of `output`: a sensor's colour
/// path when it has a tuning, its gamma otherwise.
pub struct Cpu {
    output: Output,
    tuned: Option<TunedColour>,
    buffers: colour::Buffers,
    fallback_buffers: bayer::Buffers,
}

impl Cpu {
    pub fn new(model: SensorModel, output: Output) -> Cpu {
        Cpu {
            output,
            tuned: model.tuning().map(TunedColour::new),
            buffers: colour::Buffers::default(),
            fallback_buffers: bayer::Buffers::default(),
        }
    }
}

impl Processor for Cpu {
    fn develop(&mut self, frame: &RawFrame, development: &Development, images: Images) -> Measures {
        let settings = development.settings;
        let conversion = Conversion {
            output: self.output,
            rotate_180: settings.capture.rotation == 180,
            channel_means: development.channel_means,
            green_mean: development.green_mean,
            row_step: MEASURED_ROW_STEP,
            threads: development.threads,
        };
        match &self.tuned {
            Some(tuned) => develop_tuned(
                frame,
                &conversion,
                settings,
                development.gains,
                tuned,
                images,
                &mut self.buffers,
            ),
            None => bayer::develop(
                frame,
                development.tone,
                development.gains,
                &conversion,
                images,
                &mut self.fallback_buffers,
            ),
        }
    }

    fn averages_2x2(&self) -> bool {
        true
    }
}

/// A sensor's tuning, and the table of its contrast curve.
pub struct TunedColour {
    pub tuning: &'static Tuning,
    contrast: ContrastTable,
}

impl TunedColour {
    pub fn new(tuning: &'static Tuning) -> TunedColour {
        TunedColour {
            tuning,
            contrast: ContrastTable::new(tuning),
        }
    }
}

/// `raw` through `tuned`'s colour path as `conversion` asks, into `images`
/// through `buffers`, at the colour temperature of `gains`, with the colour
/// correction matrix and the chroma denoise as `settings` switch them.
pub fn develop_tuned(
    raw: &RawFrame,
    conversion: &Conversion,
    settings: &ColourSettings,
    gains: Gains,
    tuned: &TunedColour,
    images: Images,
    buffers: &mut colour::Buffers,
) -> Measures {
    let kelvin = tuned.tuning.colour_temperature(gains);
    let shading = tuned.tuning.lens_shading(kelvin);
    let colour = Colour {
        black_level: settings.capture.black_level,
        shading: &shading,
        white_balance: gains,
        matrix: if settings.ccm {
            tuned.tuning.colour_matrix(kelvin)
        } else {
            colour::IDENTITY
        },
        contrast: &tuned.contrast,
        denoise: settings.denoise,
    };
    colour::develop(raw, &colour, conversion, images, buffers)
}

#[cfg(test)]
pub(crate) mod tests {
    use std::time::{Duration, Instant};

    use super::*;
    use crate::bayer::tests::padded_packed12;
    use crate::bayer::Layout;
    use crate::scale;
    use crate::tuning::imx477;

    // Noise over a gradient down and across, so that every row differs.
    pub(crate) fn samples(width: usize, height: usize) -> Vec<u16> {
        let mut state = 0x2545_f491u32;
        (0..width * height)
            .map(|i| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                let (x, y) = (i % width, i / width);
                let gradient = (y * 2400 / height + x * 600 / width) as u32;
                (200 + gradient + state % 900).min(4095) as u16
            })
            .collect()
    }

    // The image and measures of a frame, the means as bits to compare exactly.
    type Outcome = (Vec<u8>, Option<[u64; 3]>, Option<u64>);

    fn outcome(rgb: &[u8], measures: Measures) -> Outcome {
        (
            rgb.to_vec(),
            measures.channel_means.map(|means| means.map(f64::to_bits)),
            measures.green_mean.map(f64::to_bits),
        )
    }

    // FNV-1a of a frame's image, then of its means' bits.
    fn digest(rgb: &[u8], measures: Measures) -> u64 {
        let means = measures.channel_means.into_iter().flatten();
        let bits = means
            .chain(measures.green_mean)
            .flat_map(|mean| mean.to_bits().to_le_bytes());
        rgb.iter()
            .copied()
            .chain(bits)
            .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
                (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3)
            })
    }

    #[derive(Clone, Copy, Debug)]
    pub(crate) enum Path {
        Denoised,
        Undenoised,
        Untuned,
    }

    #[test]
    fn a_frame_converts_to_the_same_image_and_measures_on_any_number_of_threads() {
        let tuned = TunedColour::new(&imx477::TUNING);
        let tone = Tone::with_sample_bits(256, 2.2, 12);
        let gains = Gains {
            red: 2.1,
            blue: 1.6,
        };
        // The digests of the conversion on one thread before it was split
        // into bands.
        #[rustfmt::skip]
        let pinned = [
            ((24, 46), Output::Full, false, Path::Denoised, 0x5adc1b5784f7a6df),
            ((24, 46), Output::Full, false, Path::Undenoised, 0x77d9d3238a8e2a9a),
            ((24, 46), Output::Full, false, Path::Untuned, 0xfa1d284195545234),
            ((24, 46), Output::Full, true, Path::Denoised, 0xabd2abe75c2af1e9),
            ((24, 46), Output::Full, true, Path::Undenoised, 0xe02c8e3b04a8abca),
            ((24, 46), Output::Full, true, Path::Untuned, 0xbe584640e4e37f70),
            ((24, 46), Output::Half, false, Path::Denoised, 0xa4169b1baac71cf3),
            ((24, 46), Output::Half, false, Path::Undenoised, 0x7c01efd2f3ddbcbb),
            ((24, 46), Output::Half, false, Path::Untuned, 0x1a25c91807e49859),
            ((24, 46), Output::Half, true, Path::Denoised, 0xd1bc07eb69191829),
            ((24, 46), Output::Half, true, Path::Undenoised, 0x60b1c77294f02b35),
            ((24, 46), Output::Half, true, Path::Untuned, 0xd813e5060cc7f6bf),
            ((36, 6), Output::Full, false, Path::Denoised, 0x896da32606cabe67),
            ((36, 6), Output::Full, false, Path::Undenoised, 0x23424f1951fbf106),
            ((36, 6), Output::Full, false, Path::Untuned, 0x02d67db56bc545df),
            ((36, 6), Output::Full, true, Path::Denoised, 0x4619a8a968ff5bb3),
            ((36, 6), Output::Full, true, Path::Undenoised, 0xdb2ebcc5fada1634),
            ((36, 6), Output::Full, true, Path::Untuned, 0x1a4a7bf9f48e8f87),
            ((36, 6), Output::Half, false, Path::Denoised, 0xd44a33ae59ed2d90),
            ((36, 6), Output::Half, false, Path::Undenoised, 0x986243c7ea2645f1),
            ((36, 6), Output::Half, false, Path::Untuned, 0x6d2b63032f973687),
            ((36, 6), Output::Half, true, Path::Denoised, 0x4e39a53de350fc12),
            ((36, 6), Output::Half, true, Path::Undenoised, 0xe68e692b564a01c9),
            ((36, 6), Output::Half, true, Path::Untuned, 0x3f58b52486d9842b),
        ];
        for ((width, height), output, rotate_180, path, expected) in pinned {
            let stride = width * 3 / 2 + 6;
            let raw = padded_packed12(&samples(width, height), width, stride);
            let frame = RawFrame {
                raw: &raw,
                width,
                height,
                row_stride: stride,
                layout: Layout::Packed12,
            };
            let settings = ColourSettings {
                denoise: !matches!(path, Path::Undenoised),
                ..ColourSettings::default()
            };
            for threads in 1..=4 {
                let conversion = Conversion {
                    output,
                    rotate_180,
                    channel_means: true,
                    green_mean: true,
                    row_step: MEASURED_ROW_STEP,
                    threads,
                };
                let mut rgb = Vec::new();
                let measures = match path {
                    Path::Untuned => bayer::develop(
                        &frame,
                        &tone,
                        gains,
                        &conversion,
                        Images {
                            rgb: &mut rgb,
                            averaged: None,
                        },
                        &mut bayer::Buffers::default(),
                    ),
                    _ => develop_tuned(
                        &frame,
                        &conversion,
                        &settings,
                        gains,
                        &tuned,
                        Images {
                            rgb: &mut rgb,
                            averaged: None,
                        },
                        &mut colour::Buffers::default(),
                    ),
                };
                assert_eq!(
                    digest(&rgb, measures),
                    expected,
                    "{width}x{height} {output:?} rotated {rotate_180} {path:?} on {threads} threads"
                );
            }
        }
    }

    #[test]
    fn a_frame_converted_on_several_threads_is_the_one_converted_on_one() {
        let tuned = TunedColour::new(&imx477::TUNING);
        let tone = Tone::with_sample_bits(256, 2.2, 12);
        let gains = Gains {
            red: 2.1,
            blue: 1.6,
        };
        // 23, 25 and 11 rows of RGGB cells split unevenly in 2, 3 and 4 bands;
        // 3 rows give a fourth thread no band.
        for (width, height) in [(24, 46), (24, 50), (32, 22), (36, 6)] {
            let stride = width * 3 / 2 + 6;
            let raw = padded_packed12(&samples(width, height), width, stride);
            let frame = RawFrame {
                raw: &raw,
                width,
                height,
                row_stride: stride,
                layout: Layout::Packed12,
            };
            for output in [Output::Full, Output::Half] {
                for rotate_180 in [false, true] {
                    for (denoise, ccm) in [(true, true), (false, true), (true, false)] {
                        let settings = ColourSettings {
                            denoise,
                            ccm,
                            ..ColourSettings::default()
                        };
                        let (mut rgb, mut buffers, mut fallback) = (
                            Vec::new(),
                            colour::Buffers::default(),
                            bayer::Buffers::default(),
                        );
                        let mut developed = |threads| {
                            let conversion = Conversion {
                                output,
                                rotate_180,
                                channel_means: true,
                                green_mean: true,
                                row_step: MEASURED_ROW_STEP,
                                threads,
                            };
                            let measures = develop_tuned(
                                &frame,
                                &conversion,
                                &settings,
                                gains,
                                &tuned,
                                Images {
                                    rgb: &mut rgb,
                                    averaged: None,
                                },
                                &mut buffers,
                            );
                            let tuned = outcome(&rgb, measures);
                            let measures = bayer::develop(
                                &frame,
                                &tone,
                                gains,
                                &conversion,
                                Images {
                                    rgb: &mut rgb,
                                    averaged: None,
                                },
                                &mut fallback,
                            );
                            (tuned, outcome(&rgb, measures))
                        };
                        let one = developed(1);
                        for threads in [2, 3, 4, 3, 1] {
                            assert!(
                                developed(threads) == one,
                                "{width}x{height} {output:?} rotated {rotate_180} \
                                 denoise {denoise} ccm {ccm} on {threads} threads"
                            );
                        }
                    }
                }
            }
        }
    }

    // `frame` developed along `path` into `images`, through `buffers`.
    pub(crate) fn develop_along(
        path: Path,
        frame: &RawFrame,
        conversion: &Conversion,
        images: Images,
        (buffers, fallback): &mut (colour::Buffers, bayer::Buffers),
    ) -> Measures {
        let tuned = TunedColour::new(&imx477::TUNING);
        let tone = Tone::with_sample_bits(256, 2.2, 12);
        let gains = Gains {
            red: 2.1,
            blue: 1.6,
        };
        let settings = ColourSettings {
            denoise: !matches!(path, Path::Undenoised),
            ..ColourSettings::default()
        };
        match path {
            Path::Untuned => bayer::develop(frame, &tone, gains, conversion, images, fallback),
            _ => develop_tuned(frame, conversion, &settings, gains, &tuned, images, buffers),
        }
    }

    #[test]
    fn an_image_averaged_as_it_converts_is_the_one_averaged_after() {
        // Rows of cells split unevenly; at half size, in pairs of rows.
        for (width, height) in [(24, 46), (24, 44), (32, 52), (36, 12), (36, 6)] {
            let stride = width * 3 / 2 + 6;
            let raw = padded_packed12(&samples(width, height), width, stride);
            let frame = RawFrame {
                raw: &raw,
                width,
                height,
                row_stride: stride,
                layout: Layout::Packed12,
            };
            for output in [Output::Full, Output::Half] {
                let (output_width, output_height) = output.size(width as u32, height as u32);
                if output_height % 2 != 0 {
                    continue;
                }
                for rotate_180 in [false, true] {
                    for path in [Path::Denoised, Path::Undenoised, Path::Untuned] {
                        let mut buffers = Default::default();
                        let (mut alone, mut rgb, mut averaged) =
                            (Vec::new(), vec![0xaa; 7], vec![0x55; 5]);
                        for threads in [1, 2, 3, 4, 3, 1] {
                            let conversion = Conversion {
                                output,
                                rotate_180,
                                channel_means: true,
                                green_mean: true,
                                row_step: MEASURED_ROW_STEP,
                                threads,
                            };
                            let images = Images {
                                rgb: &mut alone,
                                averaged: None,
                            };
                            let measures =
                                develop_along(path, &frame, &conversion, images, &mut buffers);
                            let expected = outcome(&alone, measures);
                            let images = Images {
                                rgb: &mut rgb,
                                averaged: Some(&mut averaged),
                            };
                            let measures =
                                develop_along(path, &frame, &conversion, images, &mut buffers);
                            let mut after = Vec::new();
                            scale::average_blocks(
                                &alone,
                                output_width as usize,
                                (2, 2),
                                1,
                                &mut after,
                            );
                            let case = format!(
                                "{width}x{height} {output:?} rotated {rotate_180} {path:?} \
                                 on {threads} threads"
                            );
                            assert!(outcome(&rgb, measures) == expected, "{case}");
                            assert!(averaged == after, "{case}");
                        }
                    }
                }
            }
        }
    }

    // Prints the host's time per frame for OVCS1's HQ camera, 2028 x 1520
    // on 3 threads, converted alone, then averaged 2 x 2 after, then
    // averaged as it converts:
    // `cargo test --release -p v4l2_capture -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn host_time_of_a_full_frame_converted_and_averaged() {
        let (width, height) = (2028, 1520);
        let stride = width * 3 / 2;
        let raw = padded_packed12(&samples(width, height), width, stride);
        let frame = RawFrame {
            raw: &raw,
            width,
            height,
            row_stride: stride,
            layout: Layout::Packed12,
        };
        let conversion = Conversion {
            output: Output::Full,
            rotate_180: false,
            channel_means: true,
            green_mean: true,
            row_step: MEASURED_ROW_STEP,
            threads: 3,
        };
        let (mut rgb, mut averaged, mut buffers) = (Vec::new(), Vec::new(), Default::default());
        // 0: converted alone; 1: then averaged; 2: averaged as it converts.
        let mut times: [Vec<Duration>; 3] = Default::default();
        for round in 0..150 {
            let way = round % 3;
            let started = Instant::now();
            let images = Images {
                rgb: &mut rgb,
                averaged: (way == 2).then_some(&mut averaged),
            };
            develop_along(Path::Denoised, &frame, &conversion, images, &mut buffers);
            if way == 1 {
                scale::average_blocks(&rgb, width, (2, 2), 3, &mut averaged);
            }
            times[way].push(started.elapsed());
        }
        let ways = [
            "converted",
            "converted, averaged after",
            "converted, averaged as it converts",
        ];
        for (way, times) in ways.iter().zip(&mut times) {
            times.sort();
            println!(
                "{way}: median {:?}, fastest {:?}",
                times[times.len() / 2],
                times[0]
            );
        }
    }
}
