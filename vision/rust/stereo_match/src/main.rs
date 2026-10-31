//! The stereo Port of `VisionCore.Stereo.Matcher`: runs the native segments
//! of `VisionCore.Stereo.Pipeline`s, each configured once and kept, with
//! what its stages carry, until it is released. See `protocol` for the
//! requests and replies; log records may come before any reply.
//!
//! Requests are read and parsed, computed, and replied to on three threads,
//! one request at a time on each: a request waiting behind the one being
//! computed is read meanwhile, and the previous reply written. Replies come
//! in the order of the requests.
//!
//! `stereo_match [--threads N]` computes on N threads, by default one per core.

use std::collections::HashMap;
use std::io;
use std::sync::mpsc;

use framing::{log_record, read_record, LogLevel, Writer};
use stereo_match::protocol::{self, Request, TAG_CONFIGURED};
use stereo_match::segment::{Outputs, Segment};

fn main() -> io::Result<()> {
    match serve() {
        // The Port was closed, by a timeout or the BEAM stopping.
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(()),
        served => served,
    }
}

fn threads(arguments: &[String]) -> Result<usize, String> {
    match arguments {
        [] => Ok(std::thread::available_parallelism().map_or(1, |threads| threads.get())),
        [flag, count] if flag == "--threads" => match count.parse() {
            Ok(threads) if threads > 0 => Ok(threads),
            _ => Err(format!("--threads takes a positive integer, got {count}")),
        },
        other => Err(format!("usage: stereo_match [--threads N], got {other:?}")),
    }
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
extern "C" {
    fn mallopt(parameter: i32, value: i32) -> i32;
    fn fcntl(fd: i32, command: i32, value: i32) -> i32;
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
const M_TRIM_THRESHOLD: i32 = -1;
#[cfg(all(target_os = "linux", target_env = "gnu"))]
const M_MMAP_THRESHOLD: i32 = -3;
#[cfg(all(target_os = "linux", target_env = "gnu"))]
const F_SETPIPE_SZ: i32 = 1031;
/// A pair's frames, or its outputs, in one go.
#[cfg(all(target_os = "linux", target_env = "gnu"))]
const PIPE_BYTES: i32 = 4 << 20;

/// Keeps the pair-sized buffers freed after each pair in the heap, so the
/// next pair's are not faulted in again, and lets a pair's frames and
/// outputs through the Port's pipes in fewer wake-ups.
#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn tune_memory_and_pipes() {
    // SAFETY: plain libc calls; a failure leaves the defaults.
    unsafe {
        // glibc refuses a threshold above 32 MiB.
        mallopt(M_MMAP_THRESHOLD, 16 << 20);
        mallopt(M_TRIM_THRESHOLD, 512 << 20);
        for fd in [0, 1] {
            // Above `/proc/sys/fs/pipe-max-size` only as root.
            if fcntl(fd, F_SETPIPE_SZ, PIPE_BYTES) < 0 {
                fcntl(fd, F_SETPIPE_SZ, 1 << 20);
            }
        }
    }
}

#[cfg(not(all(target_os = "linux", target_env = "gnu")))]
fn tune_memory_and_pipes() {}

/// What the computing thread hands the writing one.
enum Reply {
    Configured,
    Outputs(Outputs),
    Refused(String),
}

fn serve() -> io::Result<()> {
    tune_memory_and_pipes();
    let out = Writer::from_stdout_redirecting()?;
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let threads = match threads(&arguments) {
        Ok(threads) => threads,
        Err(reason) => {
            out.write_record(&log_record(LogLevel::Error, &reason))?;
            return Ok(());
        }
    };
    out.write_record(&log_record(
        LogLevel::Info,
        &format!("computing on {threads} threads"),
    ))?;
    let (requests, parsed) = mpsc::sync_channel(1);
    let (replies, computed) = mpsc::sync_channel(1);
    std::thread::scope(|scope| {
        let reader = scope.spawn(move || -> io::Result<()> {
            let mut input = io::stdin().lock();
            while let Some(request) = read_record(&mut input)? {
                if requests.send(protocol::parse(&request)).is_err() {
                    break;
                }
            }
            Ok(())
        });
        let out = &out;
        let writer = scope.spawn(move || -> io::Result<()> {
            for reply in computed {
                match reply {
                    Reply::Configured => out.write_record(&[TAG_CONFIGURED])?,
                    Reply::Outputs((outputs, times_us)) => {
                        let parts = protocol::outputs_record(&times_us, &outputs);
                        let parts: Vec<&[u8]> = parts.iter().map(|part| &part[..]).collect();
                        out.write_record_parts(&parts)?;
                    }
                    Reply::Refused(reason) => {
                        out.write_record(&log_record(LogLevel::Error, &reason))?;
                        out.write_record(&[])?;
                    }
                }
            }
            Ok(())
        });
        compute(threads, parsed, replies);
        // The writer ends once `compute` drops its channel; the reader at the
        // end of the input, or at its next request once the writer has failed.
        let written = writer.join().expect("the writer does not panic");
        let read = reader.join().expect("the reader does not panic");
        written.and(read)
    })
}

fn compute(
    threads: usize,
    parsed: mpsc::Receiver<Result<Request, String>>,
    replies: mpsc::SyncSender<Reply>,
) {
    let mut segments: HashMap<u32, Segment> = HashMap::new();
    for request in parsed {
        let reply = match request {
            Ok(Request::Configure {
                segment,
                geometry,
                members,
            }) => match Segment::new(geometry, &members, threads) {
                Ok(configured) => {
                    segments.insert(segment, configured);
                    Reply::Configured
                }
                Err(reason) => Reply::Refused(reason),
            },
            Ok(Request::Run {
                segment,
                inputs,
                entries,
            }) => match segments.get_mut(&segment) {
                Some(configured) => match configured.run(&inputs, entries) {
                    Ok(outputs) => Reply::Outputs(outputs),
                    Err(reason) => Reply::Refused(reason),
                },
                None => Reply::Refused(format!("segment {segment} is not configured")),
            },
            Ok(Request::Release { segment }) => {
                segments.remove(&segment);
                continue;
            }
            Err(reason) => Reply::Refused(reason),
        };
        if replies.send(reply).is_err() {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_a_thread_count() {
        let arguments = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(threads(&arguments(&[])).unwrap() >= 1);
        assert_eq!(threads(&arguments(&["--threads", "4"])), Ok(4));
        assert!(threads(&arguments(&["--threads", "0"])).is_err());
        assert!(threads(&arguments(&["-t"])).is_err());
    }
}
