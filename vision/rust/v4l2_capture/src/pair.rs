//! The stereo pair's frame loop: captures both sensors, locks the right
//! sensor's frame starts to the left one's, and writes grey frame pairs.

use std::io;
use std::os::fd::{AsFd, AsRawFd};

use framing::{metadata_record, pair_header, LogLevel, Writer};

use crate::arguments;
use crate::bayer::{self, Tone};
use crate::exposure::{self, auto_exposure, retarget, Exposure};
use crate::pairing::{Pairer, Side};
use crate::phase_lock::PhaseLock;
use crate::sensor::{FrameTiming, SensorModel};
use crate::settings::Settings;
use crate::v4l2;
use crate::{
    input, open_camera, poll, pollfd, EXPOSURE_EVERY_FRAMES, EXPOSURE_GAIN_PRESENT, POLL_TIMEOUT,
    STATISTICS_EVERY_S,
};

const PAIR_TOLERANCE_NS: i64 = 1_000_000;
// Every this many pixels are sampled for the mean grey.
const EXPOSURE_SAMPLE_STRIDE: usize = 7;

pub fn run(
    arguments: &arguments::PairArguments,
    writer: &Writer,
    log: &dyn Fn(LogLevel, &str),
) -> io::Result<()> {
    let (sensor_width, sensor_height) = (arguments.width * 2, arguments.height * 2);
    let model = arguments.left.model;
    let left = open_camera(&arguments.left, sensor_width, sensor_height)?;
    let right = open_camera(&arguments.right, sensor_width, sensor_height)?;

    let sensor_size = (sensor_width, sensor_height);
    let timing = FrameTiming::read(&left.sensor, &right.sensor, sensor_size, arguments.fps)?;
    let gain_range = left.sensor.control_range(v4l2::CID_ANALOGUE_GAIN)?;
    let frame_us = timing.frame_us();
    let set_exposure = |exposure: Exposure| -> io::Result<Exposure> {
        let lines = timing.exposure_lines(exposure.exposure_us);
        let code = model.gain_code(exposure.gain, gain_range.0, gain_range.1);
        for camera in [&left, &right] {
            camera.sensor.set_control(v4l2::CID_EXPOSURE, lines)?;
            camera.sensor.set_control(v4l2::CID_ANALOGUE_GAIN, code)?;
        }
        Ok(Exposure {
            exposure_us: timing.exposure_us(lines),
            gain: model.gain(code),
        })
    };
    // Tells the host the exposure and gain just applied, stamped with the left frame start.
    let report_exposure = |exposure: Exposure, capture_ns: i64| -> io::Result<()> {
        let mut values = [0.0; framing::METADATA_FIELDS];
        values[0] = exposure.exposure_us;
        values[1] = exposure.gain;
        writer.write_record(&metadata_record(capture_ns, EXPOSURE_GAIN_PRESENT, &values))
    };
    for camera in [&left, &right] {
        camera.sensor.set_control(v4l2::CID_VBLANK, timing.vblank)?;
    }
    let set_focus = |focus: u16| {
        for (side, camera) in [("left", &left), ("right", &right)] {
            if let Some(lens) = &camera.lens {
                if let Err(error) = lens.set_control(v4l2::CID_FOCUS_ABSOLUTE, i32::from(focus)) {
                    log(
                        LogLevel::Warning,
                        &format!("{side} lens: focus {focus}: {error}"),
                    );
                }
            }
        }
    };
    let mut settings = arguments.settings.clone();
    let mut tone = pair_tone(&settings, model);
    set_focus(settings.focus);
    if left.lens.is_none() || right.lens.is_none() {
        log(
            LogLevel::Info,
            &format!(
                "lens actuators: left {}, right {}; focus is not set without one",
                left.lens.is_some(),
                right.lens.is_some()
            ),
        );
    }
    let mut auto_exposure = auto_exposure(&settings, frame_us);
    let mut last_left_ns = None;
    report_exposure(set_exposure(settings.manual_exposure())?, 0)?;
    log(
        LogLevel::Info,
        &format!(
            "{sensor_width}x{sensor_height} line {:.1} ns, vblank {}, period {} ns, {settings:?}",
            timing.line_ns, timing.vblank, timing.period_ns
        ),
    );
    let mut left_frames = 0u32;

    let mut lock = PhaseLock::new(
        timing.period_ns,
        timing.line_ns,
        timing.vblank,
        timing.vblank_min,
        timing.vblank_max,
    );
    let mut pairer = Pairer::new(PAIR_TOLERANCE_NS);
    let mut statistics = PairStatistics::default();
    let mut statistics_since = std::time::Instant::now();
    let mut input = input::unbuffered(io::stdin().as_fd())?;
    let mut poll_descriptors = [
        pollfd(left.capture.node.as_raw_fd()),
        pollfd(right.capture.node.as_raw_fd()),
        pollfd(input.as_raw_fd()),
    ];
    loop {
        // SAFETY: `poll_descriptors` is a valid array of three pollfds.
        poll(&mut poll_descriptors, POLL_TIMEOUT)?;
        if poll_descriptors[2].revents != 0 {
            match framing::read_record(&mut input, input::MAX_SETTING_BYTES)? {
                None => return Ok(()),
                Some(record) => match settings.apply(&record) {
                    Ok(()) => {
                        tone = pair_tone(&settings, model);
                        let running = auto_exposure.exposure;
                        auto_exposure = retarget(&settings, frame_us, running, |exposure| {
                            let applied = set_exposure(exposure)?;
                            report_exposure(applied, last_left_ns.unwrap_or(0))?;
                            Ok(applied)
                        })?;
                        set_focus(settings.focus);
                        log(LogLevel::Info, &format!("settings: {settings:?}"));
                    }
                    Err(message) => log(LogLevel::Warning, &message),
                },
            }
        }
        if statistics_since.elapsed().as_secs() >= STATISTICS_EVERY_S {
            log(LogLevel::Info, &statistics.line());
            statistics = PairStatistics::default();
            statistics_since = std::time::Instant::now();
        }
        for (side, camera) in [(Side::Left, &left), (Side::Right, &right)] {
            while let Some(frame) = camera.capture.dequeue()? {
                if !camera.capture.complete(&frame) {
                    statistics.incomplete += 1;
                    camera.capture.queue(frame)?;
                    continue;
                }
                match side {
                    Side::Left => statistics.left += 1,
                    Side::Right => statistics.right += 1,
                }
                let converting = std::time::Instant::now();
                let raw = bayer::RawFrame {
                    raw: camera.capture.pixels(&frame),
                    width: sensor_width as usize,
                    height: sensor_height as usize,
                    row_stride: camera.capture.row_stride,
                    layout: camera.capture.layout,
                };
                let grey = bayer::grey_half(&raw, &tone, settings.rotation == 180);
                statistics.conversion += converting.elapsed();
                let start_ns = frame.start_ns;
                camera.capture.queue(frame)?;
                match side {
                    Side::Left => {
                        last_left_ns = Some(start_ns);
                        left_frames += 1;
                        if settings.auto_exposure
                            && left_frames.is_multiple_of(EXPOSURE_EVERY_FRAMES)
                        {
                            let mean = exposure::mean(&grey, EXPOSURE_SAMPLE_STRIDE);
                            if let Some(exposure) = auto_exposure.observe(mean) {
                                report_exposure(set_exposure(exposure)?, start_ns)?;
                            }
                        }
                    }
                    Side::Right => {
                        if let Some(left_ns) = last_left_ns {
                            if let Some(vblank) = lock.observe(left_ns, start_ns) {
                                right.sensor.set_control(v4l2::CID_VBLANK, vblank)?;
                            }
                        }
                    }
                }
                if let Some(pair) = pairer.push(side, start_ns, grey) {
                    statistics.pairs += 1;
                    let header = pair_header(
                        arguments.width as u16,
                        arguments.height as u16,
                        pair.left_ns,
                        pair.right_ns,
                    );
                    writer.write_record_parts(&[&header, &pair.left, &pair.right])?;
                }
            }
        }
    }
}

/// What the pair loop counts and times between two statistics lines.
#[derive(Default)]
struct PairStatistics {
    /// Frames converted from each side, and frames dropped as incomplete.
    left: u64,
    right: u64,
    incomplete: u64,
    pairs: u64,
    conversion: std::time::Duration,
}

impl PairStatistics {
    fn line(&self) -> String {
        let frames = u128::from((self.left + self.right).max(1));
        format!(
            "last {STATISTICS_EVERY_S} s: frames left {} right {}, pairs {}, \
             incomplete {}, {} us per conversion",
            self.left,
            self.right,
            self.pairs,
            self.incomplete,
            self.conversion.as_nanos() / 1_000 / frames
        )
    }
}

/// The tone of a `model` pair's samples, from its black level in 10 bits as the host gives it.
fn pair_tone(settings: &Settings, model: SensorModel) -> Tone {
    let sample_bits = model.sample_bits();
    let black_level = settings.black_level << (sample_bits - 10);
    Tone::with_sample_bits(black_level, settings.gamma, sample_bits)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_12_bit_pair_is_toned_over_its_full_scale_from_its_black_level_in_10_bits() {
        let settings = Settings::default();
        let tone = pair_tone(&settings, SensorModel::Imx477);
        assert_eq!(tone.grey(64 << 2), 0);
        assert!(tone.grey(2_048) < 255);
        assert_eq!(tone.grey(4_095), 255);
        let ten_bit = pair_tone(&settings, SensorModel::Imx708);
        assert_eq!((ten_bit.grey(64), ten_bit.grey(1_023)), (0, 255));
    }
}
