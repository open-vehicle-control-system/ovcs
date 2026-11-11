//! A single colour camera: captures its raw RGGB frames, demosaics each 2x2
//! cell into one RGB pixel with grey-world white balance, runs auto exposure
//! on the green channel, and writes RGB_FRAME records on stdout.

use std::io;
use std::os::fd::{AsFd, AsRawFd};

use framing::{metadata_record, rgb_frame_header, LogLevel, Writer};

use crate::arguments::SingleArguments;
use crate::bayer::{self, RawFrame, Tone};
use crate::sensor::{self, SensorModel};
use crate::settings::ColourSettings;
use crate::v4l2;
use crate::white_balance;
use crate::{
    auto_exposure, auto_exposure_from, exposure, input, open_camera, pollfd, resume_point,
    EXPOSURE_EVERY_FRAMES, EXPOSURE_GAIN_PRESENT, EXPOSURE_MARGIN_LINES, EXPOSURE_SAMPLE_STRIDE,
    STATISTICS_EVERY_S,
};

/// White balance measures every this many rows of RGGB cells.
const WHITE_BALANCE_ROW_STEP: usize = 4;

/// Captures the camera `arguments` names at its full sensor size until the
/// host closes stdin, writing each frame at half that size in each axis.
pub fn run(
    arguments: &SingleArguments,
    writer: &Writer,
    log: &dyn Fn(LogLevel, &str),
) -> io::Result<()> {
    let (sensor_width, sensor_height) = (arguments.sensor_width, arguments.sensor_height);
    let (width, height) = (sensor_width / 2, sensor_height / 2);
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
            "{sensor_width}x{sensor_height} {:?}, line {line_ns:.1} ns, vblank {vblank}, \
             period {period_ns} ns, {settings:?}",
            camera.capture.layout
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
                     {} us per conversion, white balance {gains:?}",
                    statistics[0],
                    statistics[1],
                    conversion_ns / 1_000 / u128::from(statistics[0].max(1))
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
            let rgb = bayer::rgb_half(&raw, &tone, gains, settings.capture.rotation == 180);
            if settings.awb {
                let means = bayer::channel_means(
                    &raw,
                    settings.capture.black_level,
                    WHITE_BALANCE_ROW_STEP,
                );
                gains = white_balance::grey_world(means, gains);
            }
            conversion_ns += converting.elapsed().as_nanos();
            camera.capture.queue(frame.index)?;
            last_ns = Some(frame.start_ns);
            frames += 1;
            if settings.capture.auto_exposure && frames.is_multiple_of(EXPOSURE_EVERY_FRAMES) {
                let mean = green_mean(&rgb, EXPOSURE_SAMPLE_STRIDE);
                if let Some((exposure_us, gain)) = auto_exposure.observe(mean) {
                    report_exposure(set_exposure(exposure_us, gain)?, frame.start_ns)?;
                }
            }
            writer.write_record_parts(&[
                &rgb_frame_header(width as u16, height as u16, frame.start_ns),
                &rgb,
            ])?;
        }
    }
}

/// The mean green of every `stride`-th pixel of 8-bit RGB `rgb`.
fn green_mean(rgb: &[u8], stride: usize) -> f64 {
    exposure::mean(rgb.get(1..).unwrap_or_default(), 3 * stride)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_exposure_measures_the_green_channel() {
        let rgb = [10, 100, 20, 30, 200, 40, 250, 60, 250];
        assert_eq!(green_mean(&rgb, 1), 120.0);
        assert_eq!(green_mean(&rgb, 2), 80.0);
        assert_eq!(green_mean(&[], 1), 0.0);
    }
}
