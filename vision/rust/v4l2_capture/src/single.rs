//! A single colour camera: captures its raw RGGB frames, demosaics them at
//! the capture's size or each 2x2 cell into one pixel, with grey-world white
//! balance, runs auto exposure on the green of the RGGB cells as the image
//! tones it, and writes RGB_FRAME records on stdout, each frame converted in
//! bands of rows on as many threads as `threads` sets. A sensor with a tuning
//! takes its colour path (`colour`): lens shading, white balance, the colour
//! correction matrix of its colour temperature, the chroma denoise and the
//! contrast curve; another one its gamma.

use std::io;
use std::os::fd::{AsFd, AsRawFd};

use framing::{metadata_record, rgb_frame_header, LogLevel, Writer};

use crate::arguments::SingleArguments;
use crate::bands::{Conversion, Developed};
use crate::bayer::{self, RawFrame, Tone};
use crate::colour::{self, Colour, ContrastTable};
use crate::sensor::{self, SensorModel};
use crate::settings::ColourSettings;
use crate::tuning::Tuning;
use crate::v4l2;
use crate::white_balance::{self, Gains};
use crate::{
    auto_exposure, auto_exposure_from, input, open_camera, pollfd, resume_point,
    EXPOSURE_EVERY_FRAMES, EXPOSURE_GAIN_PRESENT, EXPOSURE_MARGIN_LINES, STATISTICS_EVERY_S,
};

/// White balance and auto exposure measure every this many rows of RGGB
/// cells, the same cells whatever the output's size.
const MEASURED_ROW_STEP: usize = 4;

/// Captures the camera `arguments` names at its full sensor size until the
/// host closes stdin, writing each frame at the size of `arguments.output`.
pub fn run(
    arguments: &SingleArguments,
    writer: &Writer,
    log: &dyn Fn(LogLevel, &str),
) -> io::Result<()> {
    let (sensor_width, sensor_height) = (arguments.sensor_width, arguments.sensor_height);
    let (width, height) = arguments.output.size(sensor_width, sensor_height);
    let model = SensorModel::for_sensor(&arguments.camera.sensor);
    let camera = open_camera(&arguments.camera, sensor_width, sensor_height)?;
    let sensor = &camera.sensor;

    let hblank = sensor.control(v4l2::CID_HBLANK)?;
    let pixel_rate = sensor.control64(v4l2::CID_PIXEL_RATE)?;
    let line_ns = sensor::line_ns(sensor_width, hblank as u32, pixel_rate as u64);
    let (vblank_min, vblank_max) = sensor.control_range(v4l2::CID_VBLANK)?;
    let frame_lines = (1e9 / f64::from(arguments.fps) / line_ns).round() as i32;
    let vblank = (frame_lines - sensor_height as i32).clamp(vblank_min, vblank_max);
    let period_ns = (f64::from(sensor_height as i32 + vblank) * line_ns).round() as i64;
    let gain_range = sensor.control_range(v4l2::CID_ANALOGUE_GAIN)?;
    let frame_us = period_ns as f64 / 1_000.0;
    let max_exposure_lines = sensor_height as i32 + vblank - EXPOSURE_MARGIN_LINES;
    let set_exposure = |exposure_us: f64, gain: f64| -> io::Result<(f64, f64)> {
        let lines = ((exposure_us * 1_000.0 / line_ns).round() as i32).clamp(1, max_exposure_lines);
        let code = model.gain_code(gain, gain_range.0, gain_range.1);
        sensor.set_control(v4l2::CID_EXPOSURE, lines)?;
        sensor.set_control(v4l2::CID_ANALOGUE_GAIN, code)?;
        Ok((f64::from(lines) * line_ns / 1_000.0, model.gain(code)))
    };
    // Tells the host the exposure and gain just applied, stamped with a frame start.
    let report_exposure = |(exposure_us, gain): (f64, f64), capture_ns: i64| -> io::Result<()> {
        let mut values = [0.0; framing::METADATA_FIELDS];
        values[0] = exposure_us;
        values[1] = gain;
        writer.write_record(&metadata_record(capture_ns, EXPOSURE_GAIN_PRESENT, &values))
    };
    sensor.set_control(v4l2::CID_VBLANK, vblank)?;

    let tone_for = |settings: &ColourSettings| {
        Tone::with_sample_bits(
            settings.capture.black_level,
            settings.capture.gamma,
            model.sample_bits(),
        )
    };
    let tuned = model.tuning().map(|tuning| TunedColour {
        tuning,
        contrast: ContrastTable::new(tuning),
    });
    let mut rgb = Vec::new();
    let mut buffers = colour::Buffers::default();
    let mut fallback_buffers = bayer::Buffers::default();
    let mut settings = arguments.settings.clone();
    let mut tone = tone_for(&settings);
    let mut gains = settings.gains();
    let mut auto_exposure = auto_exposure(&settings.capture, frame_us);
    let mut last_ns = None;
    report_exposure(
        set_exposure(
            f64::from(settings.capture.exposure_us),
            settings.capture.analogue_gain,
        )?,
        0,
    )?;
    log(
        LogLevel::Info,
        &format!(
            "{sensor_width}x{sensor_height} {:?} to {width}x{height} {:?}, line {line_ns:.1} ns, \
             vblank {vblank}, period {period_ns} ns, {settings:?}",
            camera.capture.layout, arguments.output
        ),
    );

    let mut frames = 0u32;
    // Frames converted, and frames dropped as incomplete.
    let mut statistics = [0u64; 2];
    let mut conversion_ns = 0u128;
    let mut statistics_since = std::time::Instant::now();
    let mut input = input::unbuffered(io::stdin().as_fd())?;
    let mut poll_descriptors = [pollfd(camera.capture.node.fd), pollfd(input.as_raw_fd())];
    loop {
        // SAFETY: `poll_descriptors` is a valid array of two pollfds.
        if unsafe { libc::poll(poll_descriptors.as_mut_ptr(), 2, 1_000) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(error);
        }
        if poll_descriptors[1].revents != 0 {
            match framing::read_record(&mut input)? {
                None => return Ok(()),
                Some(record) => match settings.apply(&record) {
                    Ok(()) => {
                        tone = tone_for(&settings);
                        if !settings.awb {
                            gains = settings.gains();
                        }
                        let running = (auto_exposure.exposure_us, auto_exposure.gain);
                        let resume_from = resume_point(&settings.capture, running, || {
                            let applied = set_exposure(
                                f64::from(settings.capture.exposure_us),
                                settings.capture.analogue_gain,
                            )?;
                            report_exposure(applied, last_ns.unwrap_or(0))?;
                            Ok(applied)
                        })?;
                        auto_exposure =
                            auto_exposure_from(&settings.capture, frame_us, resume_from);
                        log(LogLevel::Info, &format!("settings: {settings:?}"));
                    }
                    Err(message) => log(LogLevel::Warning, &message),
                },
            }
        }
        if statistics_since.elapsed().as_secs() >= STATISTICS_EVERY_S {
            log(
                LogLevel::Info,
                &format!(
                    "last {STATISTICS_EVERY_S} s: frames {}, incomplete {}, \
                     {} us per conversion, white balance {gains:?}{}",
                    statistics[0],
                    statistics[1],
                    conversion_ns / 1_000 / u128::from(statistics[0].max(1)),
                    tuned
                        .as_ref()
                        .map(|tuned| format!(", {:.0} K", tuned.tuning.colour_temperature(gains)))
                        .unwrap_or_default()
                ),
            );
            statistics = [0; 2];
            conversion_ns = 0;
            statistics_since = std::time::Instant::now();
        }
        while let Some(frame) = camera.capture.dequeue()? {
            if !camera.capture.complete(&frame) {
                statistics[1] += 1;
                camera.capture.queue(frame.index)?;
                continue;
            }
            statistics[0] += 1;
            let converting = std::time::Instant::now();
            let raw = RawFrame {
                raw: camera.capture.pixels(&frame),
                width: sensor_width as usize,
                height: sensor_height as usize,
                row_stride: camera.capture.row_stride,
                layout: camera.capture.layout,
            };
            frames += 1;
            let measure_exposure =
                settings.capture.auto_exposure && frames.is_multiple_of(EXPOSURE_EVERY_FRAMES);
            let conversion = Conversion {
                output: arguments.output,
                rotate_180: settings.capture.rotation == 180,
                channel_means: settings.awb,
                green_mean: measure_exposure,
                row_step: MEASURED_ROW_STEP,
                threads: settings.threads.unwrap_or(arguments.output.threads()),
            };
            let Developed {
                rgb,
                channel_means,
                green_mean,
            } = match &tuned {
                Some(tuned) => develop_tuned(
                    &raw,
                    &conversion,
                    &settings,
                    gains,
                    tuned,
                    &mut rgb,
                    &mut buffers,
                ),
                None => bayer::develop(
                    &raw,
                    &tone,
                    gains,
                    &conversion,
                    &mut rgb,
                    &mut fallback_buffers,
                ),
            };
            if let Some(means) = channel_means {
                gains = white_balance::grey_world(means, gains);
            }
            conversion_ns += converting.elapsed().as_nanos();
            camera.capture.queue(frame.index)?;
            last_ns = Some(frame.start_ns);
            if let Some(mean) = green_mean {
                if let Some((exposure_us, gain)) = auto_exposure.observe(mean) {
                    report_exposure(set_exposure(exposure_us, gain)?, frame.start_ns)?;
                }
            }
            writer.write_record_parts(&[
                &rgb_frame_header(width as u16, height as u16, frame.start_ns),
                rgb,
            ])?;
        }
    }
}

/// A sensor's tuning, and the table of its contrast curve.
struct TunedColour {
    tuning: &'static Tuning,
    contrast: ContrastTable,
}

/// `raw` through `tuned`'s colour path as `conversion` asks, into `rgb`
/// through `buffers`, at the colour temperature of `gains`, with the colour
/// correction matrix and the chroma denoise as `settings` switch them.
fn develop_tuned<'a>(
    raw: &RawFrame,
    conversion: &Conversion,
    settings: &ColourSettings,
    gains: Gains,
    tuned: &TunedColour,
    rgb: &'a mut Vec<u8>,
    buffers: &mut colour::Buffers,
) -> Developed<'a> {
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
    colour::develop(raw, &colour, conversion, rgb, buffers)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arguments::Output;
    use crate::bayer::tests::padded_packed12;
    use crate::bayer::Layout;
    use crate::tuning::imx477;

    // Noise over a gradient down and across, so that every row differs.
    fn samples(width: usize, height: usize) -> Vec<u16> {
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

    fn outcome(developed: Developed) -> Outcome {
        (
            developed.rgb.to_vec(),
            developed.channel_means.map(|means| means.map(f64::to_bits)),
            developed.green_mean.map(f64::to_bits),
        )
    }

    // FNV-1a of a frame's image, then of its means' bits.
    fn digest(developed: Developed) -> u64 {
        let means = developed.channel_means.into_iter().flatten();
        let bits = means
            .chain(developed.green_mean)
            .flat_map(|mean| mean.to_bits().to_le_bytes());
        developed
            .rgb
            .iter()
            .copied()
            .chain(bits)
            .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
                (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3)
            })
    }

    #[derive(Clone, Copy, Debug)]
    enum Path {
        Denoised,
        Undenoised,
        Untuned,
    }

    #[test]
    fn a_frame_converts_to_the_same_image_and_measures_on_any_number_of_threads() {
        let tuned = TunedColour {
            tuning: &imx477::TUNING,
            contrast: ContrastTable::new(&imx477::TUNING),
        };
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
                let developed = match path {
                    Path::Untuned => digest(bayer::develop(
                        &frame,
                        &tone,
                        gains,
                        &conversion,
                        &mut Vec::new(),
                        &mut bayer::Buffers::default(),
                    )),
                    _ => digest(develop_tuned(
                        &frame,
                        &conversion,
                        &settings,
                        gains,
                        &tuned,
                        &mut Vec::new(),
                        &mut colour::Buffers::default(),
                    )),
                };
                assert_eq!(
                    developed, expected,
                    "{width}x{height} {output:?} rotated {rotate_180} {path:?} on {threads} threads"
                );
            }
        }
    }

    #[test]
    fn a_frame_converted_on_several_threads_is_the_one_converted_on_one() {
        let tuned = TunedColour {
            tuning: &imx477::TUNING,
            contrast: ContrastTable::new(&imx477::TUNING),
        };
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
                            (
                                outcome(develop_tuned(
                                    &frame,
                                    &conversion,
                                    &settings,
                                    gains,
                                    &tuned,
                                    &mut rgb,
                                    &mut buffers,
                                )),
                                outcome(bayer::develop(
                                    &frame,
                                    &tone,
                                    gains,
                                    &conversion,
                                    &mut rgb,
                                    &mut fallback,
                                )),
                            )
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
}
