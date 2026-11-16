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
mod cpus;
mod encoder;
mod exposure;
#[cfg(test)]
mod fixtures;
mod h264;
mod input;
mod jpeg;
mod lock;
mod nv12;
mod pair;
mod pairing;
mod plan;
mod processor;
mod scale;
mod sensor;
mod settings;
mod single;
mod tuning;
mod v4l2;
mod white_balance;

use std::io;
use std::process::ExitCode;

use exposure::AutoExposure;
use framing::{LogLevel, Writer};
use settings::Settings;
use v4l2::{Capture, Node};

const BUFFERS: u32 = 4;
// Metadata slots 0 (exposure) and 1 (gain).
const EXPOSURE_GAIN_PRESENT: u8 = 0b11;
// How long the sensors may take to register after the program starts.
const NODE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
const NODE_RETRY: std::time::Duration = std::time::Duration::from_millis(200);
const BUSY_RETRY: std::time::Duration = std::time::Duration::from_millis(200);
const STATISTICS_EVERY_S: u64 = 60;
/// The longest a frame loop waits for a frame or a setting, so it serves its
/// statistics while no frame comes.
const POLL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(1);
// Auto exposure measures every this many left frames: the sensor applies a
// change a few frames after it is set.
const EXPOSURE_EVERY_FRAMES: u32 = 4;
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
    let log = |level, message: &str| writer.log(level, message);
    let command_line: Vec<String> = std::env::args().skip(1).collect();
    match arguments::parse_command(&command_line)
        .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))
        .and_then(|command| match command {
            arguments::Command::Pair(arguments) => pair::run(&arguments, &writer, &log),
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

/// The `/dev` path of the node named `name`, waiting for a node the kernel has
/// not registered yet, as when the program starts while the sensors still probe.
fn wait_for_node(name: &str) -> io::Result<String> {
    v4l2::retry(NODE_TIMEOUT, NODE_RETRY, io::ErrorKind::NotFound, || {
        framing::host_present()?;
        v4l2::node_named(name)
    })
}

fn open_camera(nodes: &arguments::Nodes, width: u32, height: u32) -> io::Result<Camera> {
    let model = nodes.model;
    let has_lens = model.has_lens();
    let open = || -> io::Result<Camera> {
        framing::host_present()?;
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

/// The exposure and gain auto exposure, while on, applies at once to stay
/// within caps a settings change lowered.
fn capped_now(settings: &Settings, auto_exposure: &mut AutoExposure) -> Option<(f64, f64)> {
    if settings.auto_exposure {
        auto_exposure.capped()
    } else {
        None
    }
}

fn pollfd(fd: i32) -> libc::pollfd {
    libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    }
}

/// Waits up to `timeout` for an event on `descriptors`, each one's `revents`
/// set as it comes. A signal ends the wait with no event, as a timeout does.
fn poll(descriptors: &mut [libc::pollfd], timeout: std::time::Duration) -> io::Result<()> {
    let timeout_ms = i32::try_from(timeout.as_millis()).unwrap_or(i32::MAX);
    // SAFETY: `descriptors` is a valid array of `descriptors.len()` pollfds.
    let polled = unsafe {
        libc::poll(
            descriptors.as_mut_ptr(),
            descriptors.len() as libc::nfds_t,
            timeout_ms,
        )
    };
    if polled < 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
        for descriptor in descriptors {
            descriptor.revents = 0;
        }
    }
    Ok(())
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

    #[test]
    fn lowered_caps_apply_at_once_to_auto_exposure_and_never_to_manual_values() {
        let mut settings = Settings::default();
        settings.apply(b"auto_exposure=false").unwrap();
        settings.apply(b"max_exposure_us=1000").unwrap();
        let mut auto_exposure = auto_exposure_from(&settings, 33_333.0, (8_000.0, 2.0));
        assert_eq!(capped_now(&settings, &mut auto_exposure), None);

        settings.apply(b"auto_exposure=true").unwrap();
        assert_eq!(
            capped_now(&settings, &mut auto_exposure),
            Some((1_000.0, 16.0))
        );
    }
}
