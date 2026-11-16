//! libcamera's stderr, forwarded as LOG records.

use std::ffi::c_int;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::os::fd::{FromRawFd, RawFd};
use std::sync::Arc;
use std::thread;

use framing::{LogLevel, Writer};

/// Points stderr at a pipe and returns its read end, for `forward_stderr`.
pub fn redirect_stderr() -> Option<RawFd> {
    let mut pipe_fds = [0 as c_int; 2];
    // SAFETY: plain fd syscalls on fds this function owns.
    unsafe {
        if libc::pipe(pipe_fds.as_mut_ptr()) != 0 {
            return None;
        }
        libc::dup2(pipe_fds[1], libc::STDERR_FILENO);
        libc::close(pipe_fds[1]);
    }
    Some(pipe_fds[0])
}

/// libcamera writes its own log to stderr: each line becomes a LOG record.
pub fn forward_stderr(read_fd: RawFd, writer: Arc<Writer>) {
    // SAFETY: `read_fd` is the pipe's read end, owned from here on.
    let pipe = unsafe { File::from_raw_fd(read_fd) };
    thread::spawn(move || {
        for line in BufReader::new(pipe).split(b'\n').map_while(Result::ok) {
            let line = String::from_utf8_lossy(&line);
            let level = if line.contains(" ERROR ") || line.contains(" FATAL ") {
                LogLevel::Error
            } else if line.contains(" WARN ") {
                LogLevel::Warning
            } else {
                LogLevel::Info
            };
            writer.log(level, &format!("libcamera: {line}"));
        }
    });
}
