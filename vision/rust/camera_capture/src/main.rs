//! `camera_capture`: one libcamera sensor, YUV420 encoded to JPEG FRAME
//! records on stdout; `Name=value` controls arrive on stdin, and stdin EOF
//! stops the capture.

mod args;
#[cfg(feature = "device")]
mod capture;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod controls;

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

    #[cfg(feature = "device")]
    if let Some(read_fd) = stderr_pipe {
        capture::forward_stderr(read_fd, Arc::clone(&writer));
    }

    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = match args::parse(&argv) {
        Ok(args) => args,
        Err(message) => {
            log(&writer, LogLevel::Warning, &message);
            exit(2);
        }
    };

    log(
        &writer,
        LogLevel::Info,
        &format!(
            "camera={} {}x{} @{} fps",
            args.camera_id, args.width, args.height, args.fps
        ),
    );

    #[cfg(feature = "device")]
    exit(capture::run(&args, &writer));

    #[cfg(not(feature = "device"))]
    {
        log(&writer, LogLevel::Error, "built without the device feature");
        exit(1);
    }
}
