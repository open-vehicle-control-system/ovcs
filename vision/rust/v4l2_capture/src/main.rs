//! Captures two IMX708 (Raspberry Pi Camera Module 3) or IMX296 sensors over
//! raw V4L2, locks the right sensor's frame starts to the left one's, and writes grey
//! frame pairs as `{:packet, 4}` records on stdout. The command line names
//! each side's capture node and sensor subdevice. Given one capture node and
//! sensor instead, it captures that camera in colour (see `single`). Records
//! on stdin change a setting each (`name=value`, see `settings`); stdin EOF
//! stops it.

mod arguments;
mod bands;
mod bayer;
mod colour;
mod exposure;
mod input;
mod jpeg;
mod lock;
mod pairing;
mod processor;
mod scale;
mod sensor;
mod settings;
mod single;
mod tuning;
mod v4l2;
mod white_balance;

use std::io;
use std::os::fd::{AsFd, AsRawFd};
use std::process::ExitCode;

use bayer::Tone;
use exposure::AutoExposure;
use framing::{log_record, metadata_record, pair_record, LogLevel, Writer};
use lock::PhaseLock;
use pairing::{Pairer, Side};
use sensor::SensorModel;
use settings::Settings;
use v4l2::{Capture, Node};

const BUFFERS: u32 = 4;
// Metadata slots 0 (exposure) and 1 (gain).
const EXPOSURE_GAIN_PRESENT: u8 = 0b11;
// How long the sensors may take to register after the program starts.
const NODE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
const NODE_RETRY: std::time::Duration = std::time::Duration::from_millis(200);
const BUSY_RETRY: std::time::Duration = std::time::Duration::from_millis(200);
const PAIR_TOLERANCE_NS: i64 = 1_000_000;
const STATISTICS_EVERY_S: u64 = 60;
// Auto exposure measures every this many left frames: the sensor applies a
// change a few frames after it is set.
const EXPOSURE_EVERY_FRAMES: u32 = 4;
// Every this many pixels are sampled for the mean grey.
const EXPOSURE_SAMPLE_STRIDE: usize = 7;
// The exposure ends this many lines before the frame does.
const EXPOSURE_MARGIN_LINES: i32 = 8;

struct Camera {
    capture: Capture,
    sensor: Node,
    /// The lens actuator, held while open; `None` on a system without its driver.
    lens: Option<Node>,
}

fn main() -> ExitCode {
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(error) => {
            eprintln!("v4l2_capture: stdout: {error}");
            return ExitCode::FAILURE;
        }
    };
    writer.log_panics();
    let log = |level, message: &str| {
        let _ = writer.write_record(&log_record(level, message));
    };
    let command_line: Vec<String> = std::env::args().skip(1).collect();
    match arguments::parse_command(&command_line)
        .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))
        .and_then(|command| match command {
            arguments::Command::Pair(arguments) => run(&arguments, &writer, &log),
            arguments::Command::Single(arguments) => single::run(&arguments, &writer, &log),
        }) {
        Ok(()) => ExitCode::SUCCESS,
        // The host closed the Port, at startup or by closing stdout.
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => ExitCode::SUCCESS,
        Err(error) => {
            log(LogLevel::Error, &error.to_string());
            ExitCode::FAILURE
        }
    }
}

/// `Err(BrokenPipe)` once the host has closed stdin, which ends a startup wait.
fn host_present() -> io::Result<()> {
    if framing::hung_up(io::stdin().as_fd()) {
        Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            "the host closed stdin",
        ))
    } else {
        Ok(())
    }
}

/// The `/dev` path of the node named `name`, waiting for a node the kernel has
/// not registered yet, as when the program starts while the sensors still probe.
fn wait_for_node(name: &str) -> io::Result<String> {
    v4l2::retry(NODE_TIMEOUT, NODE_RETRY, io::ErrorKind::NotFound, || {
        host_present()?;
        v4l2::node_named(name)
    })
}

fn open_camera(nodes: &arguments::Nodes, width: u32, height: u32) -> io::Result<Camera> {
    let model = SensorModel::for_sensor(&nodes.sensor);
    let has_lens = model.has_lens();
    let open = || -> io::Result<Camera> {
        host_present()?;
        let sensor = Node::open(&wait_for_node(&nodes.sensor)?)?;
        let node = Node::open(&wait_for_node(&nodes.video)?)?;
        let lens = sensor::lens_name(&nodes.sensor)
            .filter(|_| has_lens)
            .and_then(|name| v4l2::node_named(&name).ok())
            .and_then(|path| Node::open(&path).ok());
        Ok(Camera {
            capture: Capture::start(node, width, height, model.sample_bits(), BUFFERS)?,
            sensor,
            lens,
        })
    };
    // A capture that just stopped may still be releasing the device.
    v4l2::retry(NODE_TIMEOUT, BUSY_RETRY, io::ErrorKind::ResourceBusy, open)
        .map_err(|error| io::Error::new(error.kind(), format!("{}: {error}", nodes.video)))
}

fn run(
    arguments: &arguments::Arguments,
    writer: &Writer,
    log: &dyn Fn(LogLevel, &str),
) -> io::Result<()> {
    let (sensor_width, sensor_height) = (arguments.width * 2, arguments.height * 2);
    let model = SensorModel::for_sensor(&arguments.left.sensor);
    let left = open_camera(&arguments.left, sensor_width, sensor_height)?;
    let right = open_camera(&arguments.right, sensor_width, sensor_height)?;

    let hblank = left.sensor.control(v4l2::CID_HBLANK)?;
    let pixel_rate = left.sensor.control64(v4l2::CID_PIXEL_RATE)?;
    let line_ns = sensor::line_ns(sensor_width, hblank as u32, pixel_rate as u64);
    let (vblank_min, vblank_max) = right.sensor.control_range(v4l2::CID_VBLANK)?;
    let frame_lines = (1e9 / f64::from(arguments.fps) / line_ns).round() as i32;
    let nominal_vblank = (frame_lines - sensor_height as i32).clamp(vblank_min, vblank_max);
    let period_ns = (f64::from(sensor_height as i32 + nominal_vblank) * line_ns).round() as i64;
    let gain_range = left.sensor.control_range(v4l2::CID_ANALOGUE_GAIN)?;
    let frame_us = period_ns as f64 / 1_000.0;
    let max_exposure_lines = sensor_height as i32 + nominal_vblank - EXPOSURE_MARGIN_LINES;
    let set_exposure = |exposure_us: f64, gain: f64| -> io::Result<(f64, f64)> {
        let lines = ((exposure_us * 1_000.0 / line_ns).round() as i32).clamp(1, max_exposure_lines);
        let code = model.gain_code(gain, gain_range.0, gain_range.1);
        for camera in [&left, &right] {
            camera.sensor.set_control(v4l2::CID_EXPOSURE, lines)?;
            camera.sensor.set_control(v4l2::CID_ANALOGUE_GAIN, code)?;
        }
        Ok((f64::from(lines) * line_ns / 1_000.0, model.gain(code)))
    };
    // Tells the host the exposure and gain just applied, stamped with the left frame start.
    let report_exposure = |(exposure_us, gain): (f64, f64), capture_ns: i64| -> io::Result<()> {
        let mut values = [0.0; framing::METADATA_FIELDS];
        values[0] = exposure_us;
        values[1] = gain;
        writer.write_record(&metadata_record(capture_ns, EXPOSURE_GAIN_PRESENT, &values))
    };
    for camera in [&left, &right] {
        camera
            .sensor
            .set_control(v4l2::CID_VBLANK, nominal_vblank)?;
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
    let mut tone = Tone::new(settings.black_level, settings.gamma);
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
    report_exposure(
        set_exposure(f64::from(settings.exposure_us), settings.analogue_gain)?,
        0,
    )?;
    log(
        LogLevel::Info,
        &format!(
            "{sensor_width}x{sensor_height} line {line_ns:.1} ns, vblank {nominal_vblank}, \
             period {period_ns} ns, {settings:?}"
        ),
    );
    let mut left_frames = 0u32;

    let mut lock = PhaseLock::new(period_ns, line_ns, nominal_vblank, vblank_min, vblank_max);
    let mut pairer = Pairer::new(PAIR_TOLERANCE_NS);
    // Frames left and right, pairs, and frames dropped as incomplete.
    let mut statistics = [0u64; 4];
    let mut conversion_ns = 0u128;
    let mut statistics_since = std::time::Instant::now();
    let mut input = input::unbuffered(io::stdin().as_fd())?;
    let mut poll_descriptors = [
        pollfd(left.capture.node.fd),
        pollfd(right.capture.node.fd),
        pollfd(input.as_raw_fd()),
    ];
    loop {
        // SAFETY: `poll_descriptors` is a valid array of three pollfds.
        if unsafe { libc::poll(poll_descriptors.as_mut_ptr(), 3, 1_000) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(error);
        }
        if poll_descriptors[2].revents != 0 {
            match framing::read_record(&mut input)? {
                None => return Ok(()),
                Some(record) => match settings.apply(&record) {
                    Ok(()) => {
                        tone = Tone::new(settings.black_level, settings.gamma);
                        let running = (auto_exposure.exposure_us, auto_exposure.gain);
                        let resume_from = resume_point(&settings, running, || {
                            let applied = set_exposure(
                                f64::from(settings.exposure_us),
                                settings.analogue_gain,
                            )?;
                            report_exposure(applied, last_left_ns.unwrap_or(0))?;
                            Ok(applied)
                        })?;
                        auto_exposure = auto_exposure_from(&settings, frame_us, resume_from);
                        set_focus(settings.focus);
                        log(LogLevel::Info, &format!("settings: {settings:?}"));
                    }
                    Err(message) => log(LogLevel::Warning, &message),
                },
            }
        }
        if statistics_since.elapsed().as_secs() >= STATISTICS_EVERY_S {
            let frames = u128::from((statistics[0] + statistics[1]).max(1));
            log(
                LogLevel::Info,
                &format!(
                    "last {STATISTICS_EVERY_S} s: frames left {} right {}, pairs {}, \
                     incomplete {}, {} us per conversion",
                    statistics[0],
                    statistics[1],
                    statistics[2],
                    statistics[3],
                    conversion_ns / 1_000 / frames
                ),
            );
            statistics = [0; 4];
            conversion_ns = 0;
            statistics_since = std::time::Instant::now();
        }
        for (side, camera) in [(Side::Left, &left), (Side::Right, &right)] {
            while let Some(frame) = camera.capture.dequeue()? {
                if !camera.capture.complete(&frame) {
                    statistics[3] += 1;
                    camera.capture.queue(frame.index)?;
                    continue;
                }
                statistics[side as usize] += 1;
                let converting = std::time::Instant::now();
                let grey = bayer::grey_half(
                    camera.capture.pixels(&frame),
                    sensor_width as usize,
                    sensor_height as usize,
                    camera.capture.row_stride,
                    camera.capture.layout,
                    &tone,
                    settings.rotation == 180,
                );
                conversion_ns += converting.elapsed().as_nanos();
                camera.capture.queue(frame.index)?;
                match side {
                    Side::Left => {
                        last_left_ns = Some(frame.start_ns);
                        left_frames += 1;
                        if settings.auto_exposure
                            && left_frames.is_multiple_of(EXPOSURE_EVERY_FRAMES)
                        {
                            let mean = exposure::mean(&grey, EXPOSURE_SAMPLE_STRIDE);
                            if let Some((exposure_us, gain)) = auto_exposure.observe(mean) {
                                report_exposure(set_exposure(exposure_us, gain)?, frame.start_ns)?;
                            }
                        }
                    }
                    Side::Right => {
                        if let Some(left_ns) = last_left_ns {
                            if let Some(vblank) = lock.observe(left_ns, frame.start_ns) {
                                right.sensor.set_control(v4l2::CID_VBLANK, vblank)?;
                            }
                        }
                    }
                }
                if let Some(pair) = pairer.push(side, frame.start_ns, grey) {
                    statistics[2] += 1;
                    writer.write_record(&pair_record(
                        arguments.width as u16,
                        arguments.height as u16,
                        pair.left_ns,
                        pair.right_ns,
                        &pair.left,
                        &pair.right,
                    ))?;
                }
            }
        }
    }
}

fn auto_exposure(settings: &Settings, frame_us: f64) -> AutoExposure {
    let start = (f64::from(settings.exposure_us), settings.analogue_gain);
    auto_exposure_from(settings, frame_us, start)
}

/// Where auto exposure continues from after a settings change: where it ran,
/// or, while it is off, the manual values `apply_manual` gives the sensors,
/// so switching it on again starts from what they hold.
fn resume_point(
    settings: &Settings,
    running: (f64, f64),
    apply_manual: impl FnOnce() -> io::Result<(f64, f64)>,
) -> io::Result<(f64, f64)> {
    if settings.auto_exposure {
        Ok(running)
    } else {
        apply_manual()
    }
}

/// Auto exposure from `settings`, continuing from `(exposure_us, gain)`.
fn auto_exposure_from(
    settings: &Settings,
    frame_us: f64,
    (exposure_us, gain): (f64, f64),
) -> AutoExposure {
    AutoExposure {
        exposure_us,
        gain,
        max_exposure_us: f64::from(settings.max_exposure_us).min(frame_us),
        max_gain: settings.max_gain,
        target: settings.target_brightness,
        gamma: settings.gamma,
    }
}

fn pollfd(fd: i32) -> libc::pollfd {
    libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_exposure_switched_on_again_starts_from_the_manual_values() {
        let mut settings = Settings::default();
        let mut auto_exposure = auto_exposure_from(&settings, 33_333.0, (12_000.0, 3.0));

        settings.apply(b"auto_exposure=false").unwrap();
        settings.apply(b"exposure_us=5000").unwrap();
        let running = (auto_exposure.exposure_us, auto_exposure.gain);
        let resume_from = resume_point(&settings, running, || Ok((5_000.0, 1.5))).unwrap();
        auto_exposure = auto_exposure_from(&settings, 33_333.0, resume_from);

        settings.apply(b"auto_exposure=true").unwrap();
        let running = (auto_exposure.exposure_us, auto_exposure.gain);
        let resume_from = resume_point(&settings, running, || {
            panic!("no manual values while automatic")
        })
        .unwrap();
        assert_eq!(resume_from, (5_000.0, 1.5));
    }
}
