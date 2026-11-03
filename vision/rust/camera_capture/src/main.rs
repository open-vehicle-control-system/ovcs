//! `camera_capture`: one libcamera sensor's YUV420 output, written to stdout
//! as JPEG FRAME records or, with `--format grey`, as GREY_FRAME records of
//! its luma; `Name=value` controls arrive on stdin, and stdin EOF stops the
//! capture.

mod arguments;
#[cfg(feature = "device")]
mod capture;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod controls;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod grey;

use std::process::exit;
use std::sync::Arc;

use framing::{log_record, LogLevel, Writer};

/// Messages reach the BEAM's logger as LOG records: the Port does not capture stderr.
fn log(writer: &Writer, level: LogLevel, message: &str) {
    let _ = writer.write_record(&log_record(level, message));
}

fn main() {
    // Before the Writer, so that libcamera's stderr and any stray stdout both reach the forwarder.
    #[cfg(feature = "device")]
    let stderr_pipe = capture::redirect_stderr();

    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => Arc::new(writer),
        Err(_) => exit(1),
    };
    writer.log_panics();

    #[cfg(feature = "device")]
    if let Some(read_fd) = stderr_pipe {
        capture::forward_stderr(read_fd, Arc::clone(&writer));
    }

    let command_line: Vec<String> = std::env::args().skip(1).collect();
    let arguments = match arguments::parse(&command_line) {
        Ok(arguments) => arguments,
        Err(message) => {
            log(&writer, LogLevel::Warning, &message);
            exit(2);
        }
    };

    log(
        &writer,
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
        log(&writer, LogLevel::Error, "built without the device feature");
        exit(1);
    }
}
