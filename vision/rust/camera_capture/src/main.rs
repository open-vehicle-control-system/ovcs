//! `camera_capture`: one libcamera sensor's YUV420 output, written to stdout
//! as JPEG FRAME records or, with `--format grey`, as GREY_FRAME records of
//! its luma. With `--output`, a second ISP stream of the same capture is
//! written as OUTPUT_JPEG records after each frame's own, on at most
//! `--outputs-max-hz` frames a second. `Name=value` controls arrive on stdin,
//! and stdin EOF stops the capture.

mod arguments;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod cancellations;
#[cfg(feature = "device")]
mod capture;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod controls;
#[cfg(feature = "device")]
mod dmabuf;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod full_range;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod grey;
#[cfg(feature = "device")]
mod jpeg;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod layout;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod schedule;
#[cfg(feature = "device")]
mod stderr;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod streams;

use std::process::exit;
use std::sync::Arc;

use framing::{LogLevel, Writer};

fn main() {
    // Before the Writer, so that libcamera's stderr and any stray stdout both reach the forwarder.
    #[cfg(feature = "device")]
    let stderr_pipe = stderr::redirect_stderr();

    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => Arc::new(writer),
        Err(_) => exit(1),
    };
    writer.log_panics();

    #[cfg(feature = "device")]
    if let Some(read_fd) = stderr_pipe {
        stderr::forward_stderr(read_fd, Arc::clone(&writer));
    }

    let command_line: Vec<String> = std::env::args().skip(1).collect();
    let arguments = match arguments::parse(&command_line) {
        Ok(arguments) => arguments,
        Err(message) => {
            writer.log(LogLevel::Warning, &message);
            exit(2);
        }
    };

    writer.log(
        LogLevel::Info,
        &format!(
            "camera={} {}x{} @{} fps, {:?} frames",
            arguments.camera_id, arguments.width, arguments.height, arguments.fps, arguments.format
        ),
    );

    #[cfg(feature = "device")]
    exit(capture::run(&arguments, &writer));

    #[cfg(not(feature = "device"))]
    {
        writer.log(LogLevel::Error, "built without the device feature");
        exit(1);
    }
}
