//! Captures the OKdo Nano C100's two CSI cameras over V4L2, locks the right
//! sensor's frame starts to the left one's, and writes grey frame pairs as
//! `{:packet, 4}` records on stdout. Records on stdin change a setting each
//! (`name=value`, see `settings`); stdin EOF stops it.

mod args;
mod bayer;
mod exposure;
mod lock;
mod pairing;
mod sensor;
mod settings;
mod v4l2;

use std::io;
use std::process::ExitCode;

use bayer::Tone;
use exposure::AutoExposure;
use framing::{log_record, pair_record, LogLevel, Writer};
use lock::PhaseLock;
use pairing::{Pairer, Side};
use settings::Settings;
use v4l2::{Capture, Node};

const LEFT_VIDEO: &str = "54080000.vi-output-0";
const LEFT_SENSOR: &str = "imx708 5-001a";
const RIGHT_VIDEO: &str = "54080000.vi-output-4";
const RIGHT_SENSOR: &str = "imx708 6-001a";
const BUFFERS: u32 = 4;
// How long the sensors may take to register after the program starts.
const NODE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
const PAIR_TOLERANCE_NS: i64 = 1_000_000;
const STATS_EVERY_S: u64 = 60;
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
    let log = |level, message: &str| {
        let _ = writer.write_record(&log_record(level, message));
    };
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let result = args::parse(&argv)
        .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))
        .and_then(|args| run(&args, &writer, &log));
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            log(LogLevel::Error, &error.to_string());
            ExitCode::FAILURE
        }
    }
}

fn open_camera(video: &str, sensor_name: &str, width: u32, height: u32) -> io::Result<Camera> {
    let open = || -> io::Result<Camera> {
        let sensor = Node::open(&v4l2::wait_for_node(sensor_name, NODE_TIMEOUT)?)?;
        let node = Node::open(&v4l2::wait_for_node(video, NODE_TIMEOUT)?)?;
        let lens = sensor::lens_name(sensor_name)
            .and_then(|name| v4l2::node_named(&name).ok())
            .and_then(|path| Node::open(&path).ok());
        Ok(Camera {
            capture: Capture::start(node, width, height, BUFFERS)?,
            sensor,
            lens,
        })
    };
    open().map_err(|error| io::Error::new(error.kind(), format!("{video}: {error}")))
}

fn run(args: &args::Args, writer: &Writer, log: &dyn Fn(LogLevel, &str)) -> io::Result<()> {
    let (sensor_width, sensor_height) = (args.width * 2, args.height * 2);
    let left = open_camera(LEFT_VIDEO, LEFT_SENSOR, sensor_width, sensor_height)?;
    let right = open_camera(RIGHT_VIDEO, RIGHT_SENSOR, sensor_width, sensor_height)?;

    let hblank = left.sensor.control(v4l2::CID_HBLANK)?;
    let pixel_rate = left.sensor.control64(v4l2::CID_PIXEL_RATE)?;
    let line_ns = sensor::line_ns(sensor_width, hblank as u32, pixel_rate as u64);
    let (vblank_min, vblank_max) = right.sensor.control_range(v4l2::CID_VBLANK)?;
    let frame_lines = (1e9 / f64::from(args.fps) / line_ns).round() as i32;
    let vblank0 = (frame_lines - sensor_height as i32).clamp(vblank_min, vblank_max);
    let period_ns = (f64::from(sensor_height as i32 + vblank0) * line_ns).round() as i64;
    let gain_range = left.sensor.control_range(v4l2::CID_ANALOGUE_GAIN)?;
    let frame_us = period_ns as f64 / 1_000.0;
    let max_exposure_lines = sensor_height as i32 + vblank0 - EXPOSURE_MARGIN_LINES;
    let set_exposure = |exposure_us: f64, gain: f64| -> io::Result<()> {
        let lines = ((exposure_us * 1_000.0 / line_ns).round() as i32).clamp(1, max_exposure_lines);
        let code = sensor::imx708_gain_code(gain, gain_range.0, gain_range.1);
        for camera in [&left, &right] {
            camera.sensor.set_control(v4l2::CID_EXPOSURE, lines)?;
            camera.sensor.set_control(v4l2::CID_ANALOGUE_GAIN, code)?;
        }
        Ok(())
    };
    for camera in [&left, &right] {
        camera.sensor.set_control(v4l2::CID_VBLANK, vblank0)?;
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
    let mut settings = args.settings.clone();
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
    set_exposure(f64::from(settings.exposure_us), settings.analogue_gain)?;
    log(
        LogLevel::Info,
        &format!(
            "{sensor_width}x{sensor_height} line {line_ns:.1} ns, vblank {vblank0}, \
             period {period_ns} ns, {settings:?}"
        ),
    );
    let mut left_frames = 0u32;

    let mut lock = PhaseLock::new(period_ns, line_ns, vblank0, vblank_min, vblank_max);
    let mut pairer = Pairer::new(PAIR_TOLERANCE_NS);
    let mut last_left_ns = None;
    let mut stats = [0u64; 3];
    let mut convert_ns = 0u128;
    let mut stats_at = std::time::Instant::now();
    let mut fds = [
        pollfd(left.capture.node.fd),
        pollfd(right.capture.node.fd),
        pollfd(libc::STDIN_FILENO),
    ];
    loop {
        // SAFETY: `fds` is a valid array of three pollfds.
        if unsafe { libc::poll(fds.as_mut_ptr(), 3, 1_000) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(error);
        }
        if fds[2].revents != 0 {
            match framing::read_record(&mut io::stdin().lock())? {
                None => return Ok(()),
                Some(record) => match settings.apply(&record) {
                    Ok(()) => {
                        tone = Tone::new(settings.black_level, settings.gamma);
                        let running = (auto_exposure.exposure_us, auto_exposure.gain);
                        auto_exposure = auto_exposure_from(&settings, frame_us, running);
                        if !settings.auto_exposure {
                            set_exposure(f64::from(settings.exposure_us), settings.analogue_gain)?;
                        }
                        set_focus(settings.focus);
                        log(LogLevel::Info, &format!("settings: {settings:?}"));
                    }
                    Err(message) => log(LogLevel::Warning, &message),
                },
            }
        }
        if stats_at.elapsed().as_secs() >= STATS_EVERY_S {
            let frames = u128::from((stats[0] + stats[1]).max(1));
            log(
                LogLevel::Info,
                &format!(
                    "last {STATS_EVERY_S} s: frames left {} right {}, pairs {}, {} us per conversion",
                    stats[0],
                    stats[1],
                    stats[2],
                    convert_ns / 1_000 / frames
                ),
            );
            stats = [0; 3];
            convert_ns = 0;
            stats_at = std::time::Instant::now();
        }
        for (side, camera) in [(Side::Left, &left), (Side::Right, &right)] {
            while let Some(frame) = camera.capture.dequeue()? {
                stats[side as usize] += 1;
                let converting = std::time::Instant::now();
                let grey = bayer::grey_half(
                    camera.capture.pixels(&frame),
                    sensor_width as usize,
                    sensor_height as usize,
                    &tone,
                    settings.rotation == 180,
                );
                convert_ns += converting.elapsed().as_nanos();
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
                                set_exposure(exposure_us, gain)?;
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
                    stats[2] += 1;
                    writer.write_record(&pair_record(
                        args.width as u16,
                        args.height as u16,
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
