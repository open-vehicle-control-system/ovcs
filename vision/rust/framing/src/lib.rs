//! `{:packet, 4}` framing for the Port binaries: a big-endian length prefix per
//! record. Record scalars are little-endian and match the Elixir parser in
//! `VisionCore.Camera.LibCamera` byte for byte.

use std::fs::File;
use std::io::{self, IoSlice, Read, Write};
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, RawFd};
use std::sync::{Arc, Mutex, TryLockError};
use std::time::{Duration, Instant};

const TAG_FRAME: u8 = 1;
const TAG_LOG: u8 = 2;
const TAG_METADATA: u8 = 3;
const TAG_PAIR: u8 = 4;
const TAG_GREY_FRAME: u8 = 5;
const TAG_OUTPUT_FRAME: u8 = 7;
const TAG_OUTPUT_JPEG: u8 = 8;

pub const METADATA_FIELDS: usize = 8;

/// How long a panic waits for the thread writing a record before it gives up its own.
const PANIC_LOCK_WAIT: Duration = Duration::from_millis(500);
const PANIC_LOCK_RETRY: Duration = Duration::from_millis(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogLevel {
    Info = 0,
    Warning = 1,
    Error = 2,
}

#[repr(C)]
struct PollDescriptor {
    fd: RawFd,
    events: i16,
    revents: i16,
}

const POLLHUP: i16 = 0x10;
const F_SETPIPE_SZ: i32 = 1031;
/// The most an unprivileged process may ask for by default (`/proc/sys/fs/pipe-max-size`).
const UNPRIVILEGED_PIPE_BYTES: i32 = 1 << 20;

extern "C" {
    fn dup(fd: RawFd) -> RawFd;
    fn dup2(old: RawFd, new: RawFd) -> RawFd;
    fn poll(descriptors: *mut PollDescriptor, count: std::ffi::c_ulong, timeout_ms: i32) -> i32;
    fn fcntl(fd: RawFd, command: i32, ...) -> i32;
    #[cfg(test)]
    #[link_name = "pipe"]
    fn libc_pipe(ends: *mut RawFd) -> i32;
}

/// Reads one length-prefixed record of at most `max_bytes`. `None` on clean EOF or a
/// truncated record.
pub fn read_record<R: Read>(reader: &mut R, max_bytes: usize) -> io::Result<Option<Vec<u8>>> {
    let Some(length) = read_length(reader, max_bytes)? else {
        return Ok(None);
    };
    let mut body = Vec::new();
    Ok(read_body_into(reader, length, &mut body)?.then_some(body))
}

/// Waits for the next record's length prefix. `None` on clean EOF or a
/// truncated prefix; an error for a length over `max_bytes`, which no record
/// of the Port's has: the stream is out of step.
pub fn read_length<R: Read>(reader: &mut R, max_bytes: usize) -> io::Result<Option<usize>> {
    let mut prefix = [0u8; 4];
    if !read_exact_or_eof(reader, &mut prefix)? {
        return Ok(None);
    }
    let length = u32::from_be_bytes(prefix) as usize;
    if length > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("a record of {length} bytes, over the {max_bytes} taken"),
        ));
    }
    Ok(Some(length))
}

/// Reads a record's body of `length` bytes into `body` in place of its
/// contents, reusing its allocation. `false` on a truncated body.
pub fn read_body_into<R: Read>(
    reader: &mut R,
    length: usize,
    body: &mut Vec<u8>,
) -> io::Result<bool> {
    body.resize(length, 0);
    read_exact_or_eof(reader, body)
}

fn read_exact_or_eof<R: Read>(reader: &mut R, buffer: &mut [u8]) -> io::Result<bool> {
    match reader.read_exact(buffer) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Ok(false),
        Err(error) => Err(error),
    }
}

/// Whether the other end of the pipe `descriptor` reads from has closed, as
/// the host does when it closes the Port: a program waiting at startup stops
/// then instead of holding its devices.
pub fn hung_up(descriptor: BorrowedFd<'_>) -> bool {
    let mut polled = PollDescriptor {
        fd: descriptor.as_raw_fd(),
        events: 0,
        revents: 0,
    };
    // SAFETY: one valid descriptor, polled without waiting.
    unsafe { poll(&mut polled, 1, 0) == 1 && polled.revents & POLLHUP != 0 }
}

/// Enlarges the pipe `descriptor` reads from or writes to so it holds `bytes`, or, refused, 1
/// MiB: a record that fits is written in one go rather than in turns with its reader.
/// Returns the pipe's size.
pub fn enlarge_pipe(descriptor: BorrowedFd<'_>, bytes: usize) -> io::Result<usize> {
    let set = |bytes: i32| {
        // SAFETY: a plain fcntl on a valid descriptor; a failure leaves the pipe as it was.
        match unsafe { fcntl(descriptor.as_raw_fd(), F_SETPIPE_SZ, bytes) } {
            size if size < 0 => Err(io::Error::last_os_error()),
            size => Ok(size as usize),
        }
    };
    set(i32::try_from(bytes).unwrap_or(i32::MAX)).or_else(|_| set(UNPRIVILEGED_PIPE_BYTES))
}

/// Record output on the real stdout. Libraries that print to stdout would
/// corrupt the framing, so fd 1 is pointed at stderr.
pub struct Writer {
    stdout: Arc<Mutex<File>>,
}

impl Writer {
    pub fn from_stdout_redirecting() -> io::Result<Writer> {
        // SAFETY: plain fd syscalls; the dup'd fd is owned by the returned File.
        unsafe {
            let saved = dup(1);
            if saved < 0 {
                return Err(io::Error::last_os_error());
            }
            let stdout = File::from_raw_fd(saved);
            if dup2(2, 1) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Writer::from_file(stdout))
        }
    }

    /// Record output on `output`.
    pub fn from_file(output: File) -> Writer {
        Writer {
            stdout: Arc::new(Mutex::new(output)),
        }
    }

    /// Also sends a panic's message as an error LOG record before the usual
    /// report on stderr, which the Port does not read. It waits its turn
    /// behind a thread writing a record, which it would cut, and is skipped
    /// when that thread still writes after `PANIC_LOCK_WAIT`, or is the one
    /// panicking.
    pub fn log_panics(&self) {
        self.log_panics_waiting(PANIC_LOCK_WAIT, || std::thread::sleep(PANIC_LOCK_RETRY));
    }

    /// `log_panics`, waiting up to `wait` for the lock, with `pause` between two tries.
    fn log_panics_waiting(&self, wait: Duration, pause: impl Fn() + Send + Sync + 'static) {
        let stdout = Arc::clone(&self.stdout);
        let report = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let deadline = Instant::now() + wait;
            // Never `lock`: the panicking thread may hold the lock itself.
            let output = loop {
                match stdout.try_lock() {
                    Ok(output) => break Some(output),
                    Err(TryLockError::Poisoned(poisoned)) => break Some(poisoned.into_inner()),
                    Err(TryLockError::WouldBlock) if Instant::now() < deadline => pause(),
                    Err(TryLockError::WouldBlock) => break None,
                }
            };
            if let Some(mut output) = output {
                let record = log_record(LogLevel::Error, &format!("panic: {info}"));
                let _ = write_parts(&mut *output, &[&record]);
                let _ = output.flush();
            }
            report(info);
        }));
    }

    /// Writes one record. Safe to call from several threads.
    pub fn write_record(&self, record: &[u8]) -> io::Result<()> {
        self.write_record_parts(&[record])
    }

    /// Writes one record of `parts`, without joining them first. Safe to
    /// call from several threads.
    pub fn write_record_parts(&self, parts: &[&[u8]]) -> io::Result<()> {
        let mut stdout = self.stdout.lock().unwrap_or_else(|e| e.into_inner());
        write_parts(&mut *stdout, parts)?;
        stdout.flush()
    }
}

/// `parts` as one record, in as few writes as `output` takes.
fn write_parts<W: Write>(output: &mut W, parts: &[&[u8]]) -> io::Result<()> {
    let length = u32::try_from(parts.iter().map(|part| part.len()).sum::<usize>())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "record too large"))?
        .to_be_bytes();
    let mut slices: Vec<IoSlice> = std::iter::once(&length[..])
        .chain(parts.iter().copied())
        .map(IoSlice::new)
        .collect();
    let mut slices = &mut slices[..];
    while !slices.is_empty() {
        match output.write_vectored(slices) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(written) => IoSlice::advance_slices(&mut slices, written),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

/// The tag, size and capture time an image record starts with.
fn image_header(tag: u8, width: u16, height: u16, capture_ns: i64) -> [u8; 13] {
    let mut header = [0; 13];
    header[0] = tag;
    header[1..3].copy_from_slice(&width.to_le_bytes());
    header[3..5].copy_from_slice(&height.to_le_bytes());
    header[5..13].copy_from_slice(&capture_ns.to_le_bytes());
    header
}

/// The start of a FRAME record, which `jpeg_length` bytes of JPEG follow.
pub fn frame_header(width: u16, height: u16, capture_ns: i64, jpeg_length: usize) -> [u8; 17] {
    let mut header = [0; 17];
    header[..13].copy_from_slice(&image_header(TAG_FRAME, width, height, capture_ns));
    header[13..].copy_from_slice(&(jpeg_length as u32).to_le_bytes());
    header
}

pub fn frame_record(width: u16, height: u16, capture_ns: i64, jpeg: &[u8]) -> Vec<u8> {
    [
        &frame_header(width, height, capture_ns, jpeg.len())[..],
        jpeg,
    ]
    .concat()
}

/// The start of a GREY_FRAME record, which `width` x `height` 8-bit grey
/// pixels follow, row-major.
pub fn grey_frame_header(width: u16, height: u16, capture_ns: i64) -> [u8; 13] {
    image_header(TAG_GREY_FRAME, width, height, capture_ns)
}

/// One 8-bit grey frame of `width` x `height`, row-major.
pub fn grey_frame_record(width: u16, height: u16, capture_ns: i64, grey: &[u8]) -> Vec<u8> {
    [&grey_frame_header(width, height, capture_ns)[..], grey].concat()
}

/// The start of an OUTPUT_FRAME record, a camera output's frame: the tag,
/// the output's index, then the size and capture time an image record
/// starts with, which `width` x `height` pixels of 8-bit red, green and
/// blue follow, row-major.
pub fn output_frame_header(output: u8, width: u16, height: u16, capture_ns: i64) -> [u8; 14] {
    let mut header = [0; 14];
    header[0] = TAG_OUTPUT_FRAME;
    header[1] = output;
    header[2..].copy_from_slice(&image_header(TAG_OUTPUT_FRAME, width, height, capture_ns)[1..]);
    header
}

/// The start of an OUTPUT_JPEG record, a camera output's frame as a JPEG:
/// an OUTPUT_FRAME record's header under its own tag, which the JPEG of
/// the `width` x `height` image follows.
pub fn output_jpeg_header(output: u8, width: u16, height: u16, capture_ns: i64) -> [u8; 14] {
    let mut header = output_frame_header(output, width, height, capture_ns);
    header[0] = TAG_OUTPUT_JPEG;
    header
}

pub fn log_record(level: LogLevel, message: &str) -> Vec<u8> {
    let mut record = Vec::with_capacity(2 + message.len());
    record.push(TAG_LOG);
    record.push(level as u8);
    record.extend_from_slice(message.as_bytes());
    record
}

/// Bit i of `present` is set when `values[i]` was reported.
pub fn metadata_record(capture_ns: i64, present: u8, values: &[f64; METADATA_FIELDS]) -> Vec<u8> {
    let mut record = Vec::with_capacity(10 + 8 * METADATA_FIELDS);
    record.push(TAG_METADATA);
    record.push(present);
    record.extend_from_slice(&capture_ns.to_le_bytes());
    for value in values {
        record.extend_from_slice(&value.to_le_bytes());
    }
    record
}

/// Two 8-bit grey frames of `width` x `height`, row-major, with their start times.
pub fn pair_record(
    width: u16,
    height: u16,
    left_ns: i64,
    right_ns: i64,
    left: &[u8],
    right: &[u8],
) -> Vec<u8> {
    let mut record = Vec::with_capacity(21 + left.len() + right.len());
    record.push(TAG_PAIR);
    record.extend_from_slice(&width.to_le_bytes());
    record.extend_from_slice(&height.to_le_bytes());
    record.extend_from_slice(&left_ns.to_le_bytes());
    record.extend_from_slice(&right_ns.to_le_bytes());
    record.extend_from_slice(left);
    record.extend_from_slice(right);
    record
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsFd;

    #[test]
    fn a_pipe_hangs_up_once_its_writing_end_closes() {
        let mut ends = [0; 2];
        // SAFETY: `ends` has room for the two descriptors.
        assert_eq!(unsafe { libc_pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both descriptors were just created and nothing else owns them.
        let (pipe_out, pipe_in) =
            unsafe { (File::from_raw_fd(ends[0]), File::from_raw_fd(ends[1])) };

        assert!(!hung_up(pipe_out.as_fd()));
        drop(pipe_in);
        assert!(hung_up(pipe_out.as_fd()));
    }

    #[test]
    fn a_pipe_is_enlarged_to_the_size_asked_or_to_one_mebibyte() {
        let mut ends = [0; 2];
        // SAFETY: `ends` has room for the two descriptors.
        assert_eq!(unsafe { libc_pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both descriptors were just created and nothing else owns them.
        let (pipe_out, _pipe_in) =
            unsafe { (File::from_raw_fd(ends[0]), File::from_raw_fd(ends[1])) };

        assert_eq!(
            enlarge_pipe(pipe_out.as_fd(), 256 << 10).unwrap(),
            256 << 10
        );
        let size = enlarge_pipe(pipe_out.as_fd(), 64 << 20).unwrap();
        assert!(size == 1 << 20 || size == 64 << 20, "{size}");
    }

    // The panic hook is the process's: one test sets it at a time.
    static PANIC_HOOK: Mutex<()> = Mutex::new(());

    // A writer and the end its records are read from.
    fn piped_writer() -> (Writer, File) {
        let mut ends = [0; 2];
        // SAFETY: `ends` has room for the two descriptors.
        assert_eq!(unsafe { libc_pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both descriptors were just created and nothing else owns them.
        let (pipe_out, pipe_in) =
            unsafe { (File::from_raw_fd(ends[0]), File::from_raw_fd(ends[1])) };
        (Writer::from_file(pipe_in), pipe_out)
    }

    fn assert_panic_record(record: &[u8], panic_message: &str) {
        assert_eq!(&record[..2], &[TAG_LOG, LogLevel::Error as u8]);
        let message = String::from_utf8(record[2..].to_vec()).unwrap();
        assert!(message.starts_with("panic: "), "{message}");
        assert!(message.contains(panic_message), "{message}");
    }

    #[test]
    fn a_panic_is_sent_as_an_error_log_record() {
        let _hook = PANIC_HOOK.lock().unwrap_or_else(|e| e.into_inner());
        let (writer, mut pipe_out) = piped_writer();
        writer.log_panics();

        let panicked = std::panic::catch_unwind(|| panic!("no frame left"));
        let _ = std::panic::take_hook();

        assert!(panicked.is_err());
        drop(writer);
        let record = read_record(&mut pipe_out, 1 << 10).unwrap().unwrap();
        assert_panic_record(&record, "no frame left");
    }

    #[test]
    fn a_panic_while_another_thread_writes_is_sent_once_that_thread_is_done() {
        let _hook = PANIC_HOOK.lock().unwrap_or_else(|e| e.into_inner());
        let (writer, mut pipe_out) = piped_writer();
        let (release, released) = std::sync::mpsc::channel::<()>();
        let (done, is_done) = std::sync::mpsc::channel::<()>();
        let (holding, is_holding) = std::sync::mpsc::channel::<()>();
        let stdout = Arc::clone(&writer.stdout);
        let holder = std::thread::spawn(move || {
            let output = stdout.lock().unwrap();
            holding.send(()).unwrap();
            released.recv().unwrap();
            drop(output);
            done.send(()).unwrap();
        });
        is_holding.recv().unwrap();
        // The first pause lets the other thread finish, as its write would.
        let (release, is_done) = (Mutex::new(release), Mutex::new(is_done));
        writer.log_panics_waiting(Duration::from_secs(60), move || {
            if release.lock().unwrap().send(()).is_ok() {
                is_done.lock().unwrap().recv().unwrap();
            }
        });

        let panicked = std::panic::catch_unwind(|| panic!("conversion failed"));
        let _ = std::panic::take_hook();

        assert!(panicked.is_err());
        holder.join().unwrap();
        drop(writer);
        let record = read_record(&mut pipe_out, 1 << 10).unwrap();
        assert_panic_record(&record.expect("the panic's record"), "conversion failed");
    }

    #[test]
    fn a_panic_gives_up_its_record_when_the_writer_stays_held() {
        let _hook = PANIC_HOOK.lock().unwrap_or_else(|e| e.into_inner());
        let (writer, mut pipe_out) = piped_writer();
        let output = writer.stdout.lock().unwrap();
        writer.log_panics_waiting(Duration::ZERO, || {});

        let panicked = std::panic::catch_unwind(|| panic!("held"));
        let _ = std::panic::take_hook();

        assert!(panicked.is_err());
        drop(output);
        drop(writer);
        assert_eq!(read_record(&mut pipe_out, 1 << 10).unwrap(), None);
    }

    #[test]
    fn frame_record_matches_cpp_layout() {
        let got = frame_record(0x0102, 0x0304, 0x0807060504030201, &[0xaa, 0xbb]);
        let want = [
            1, 0x02, 0x01, 0x04, 0x03, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 2, 0, 0, 0,
            0xaa, 0xbb,
        ];
        assert_eq!(got, want);
    }

    #[test]
    fn log_record_matches_cpp_layout() {
        assert_eq!(log_record(LogLevel::Warning, "hi"), [2, 1, b'h', b'i']);
        assert_eq!(log_record(LogLevel::Error, ""), [2, 2]);
    }

    #[test]
    fn metadata_record_matches_cpp_layout() {
        let values = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -2.0];
        let got = metadata_record(-1, 0x81, &values);
        let mut want = vec![3, 0x81];
        want.extend_from_slice(&[0xff; 8]);
        want.extend_from_slice(&1.0f64.to_le_bytes());
        want.extend_from_slice(&[0; 48]);
        want.extend_from_slice(&(-2.0f64).to_le_bytes());
        assert_eq!(got, want);
    }

    #[test]
    fn pair_record_layout() {
        let got = pair_record(2, 1, 5, 6, &[1, 2], &[3, 4]);
        let want = [
            4, 2, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4,
        ];
        assert_eq!(got, want);
    }

    #[test]
    fn grey_frame_record_layout() {
        let got = grey_frame_record(2, 1, 5, &[7, 8]);
        let want = [5, 2, 0, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 7, 8];
        assert_eq!(got, want);
    }

    #[test]
    fn output_jpeg_record_layout() {
        let got = [
            &output_jpeg_header(3, 2, 1, -5)[..],
            &[0xff, 0xd8, 0xff, 0xd9],
        ]
        .concat();
        let want = [
            8, 3, 2, 0, 1, 0, 0xfb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xd8, 0xff,
            0xd9,
        ];
        assert_eq!(got, want);
    }

    #[test]
    fn output_frame_record_layout() {
        let got = [&output_frame_header(3, 2, 1, -5)[..], &[1, 2, 3, 4, 5, 6]].concat();
        let want = [
            7, 3, 2, 0, 1, 0, 0xfb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1, 2, 3, 4, 5, 6,
        ];
        assert_eq!(got, want);
    }

    #[test]
    fn a_record_longer_than_the_maximum_is_an_error_before_it_is_read() {
        let mut input: &[u8] = &[0, 0, 0, 5, 1, 2, 3, 4, 5];
        let error = read_record(&mut input, 4).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(error.to_string(), "a record of 5 bytes, over the 4 taken");
        assert_eq!(input, [1, 2, 3, 4, 5]);

        let mut input: &[u8] = &[0, 0, 0, 5, 1, 2, 3, 4, 5];
        assert_eq!(
            read_record(&mut input, 5).unwrap(),
            Some(vec![1, 2, 3, 4, 5])
        );
        let mut input: &[u8] = &[0xff, 0xff, 0xff, 0xff];
        assert!(read_length(&mut input, 64 << 20).is_err());
    }

    #[test]
    fn read_record_returns_none_on_eof() {
        assert_eq!(read_record(&mut &[][..], 16).unwrap(), None);
    }

    #[test]
    fn read_record_returns_none_on_truncated_body() {
        let mut input: &[u8] = &[0, 0, 0, 10, 1, 2, 3, 4];
        assert_eq!(read_record(&mut input, 16).unwrap(), None);
    }

    #[test]
    fn read_record_reads_a_record() {
        let mut input: &[u8] = &[0, 0, 0, 2, 9, 8, 7];
        assert_eq!(read_record(&mut input, 16).unwrap(), Some(vec![9, 8]));
    }

    #[test]
    fn a_body_read_into_a_buffer_replaces_its_contents() {
        let mut input: &[u8] = &[0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 1, 9, 0, 0];
        let mut body = vec![7; 5];
        assert_eq!(read_length(&mut input, 16).unwrap(), Some(3));
        assert!(read_body_into(&mut input, 3, &mut body).unwrap());
        assert_eq!(body, [1, 2, 3]);
        assert_eq!(read_length(&mut input, 16).unwrap(), Some(1));
        assert!(read_body_into(&mut input, 1, &mut body).unwrap());
        assert_eq!(body, [9]);
        assert_eq!(read_length(&mut input, 16).unwrap(), None);
    }

    #[test]
    fn a_truncated_body_read_into_a_buffer_is_refused() {
        let mut input: &[u8] = &[1, 2];
        assert!(!read_body_into(&mut input, 3, &mut Vec::new()).unwrap());
    }

    /// Takes at most three bytes a write, as a full pipe may.
    struct Trickle(Vec<u8>);

    impl Write for Trickle {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let taken = bytes.len().min(3);
            self.0.extend_from_slice(&bytes[..taken]);
            Ok(taken)
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn writes_the_parts_of_a_record_after_its_length() {
        let mut trickle = Trickle(Vec::new());
        write_parts(&mut trickle, &[&[1, 2], &[], &[3, 4, 5, 6]]).unwrap();
        assert_eq!(trickle.0, [0, 0, 0, 6, 1, 2, 3, 4, 5, 6]);
    }
}
