//! `{:packet, 4}` framing for the Port binaries: a big-endian length prefix per
//! record. Record scalars are little-endian and match the Elixir parser in
//! `VisionCore.Camera.LibCamera` byte for byte.

use std::fs::File;
use std::io::{self, IoSlice, Read, Write};
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, RawFd};
use std::sync::{Arc, Mutex, TryLockError};

const TAG_FRAME: u8 = 1;
const TAG_LOG: u8 = 2;
const TAG_METADATA: u8 = 3;
const TAG_PAIR: u8 = 4;
const TAG_GREY_FRAME: u8 = 5;
const TAG_RGB_FRAME: u8 = 6;

pub const METADATA_FIELDS: usize = 8;

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

extern "C" {
    fn dup(fd: RawFd) -> RawFd;
    fn dup2(old: RawFd, new: RawFd) -> RawFd;
    fn poll(descriptors: *mut PollDescriptor, count: std::ffi::c_ulong, timeout_ms: i32) -> i32;
    #[cfg(test)]
    #[link_name = "pipe"]
    fn libc_pipe(ends: *mut RawFd) -> i32;
}

/// Reads one length-prefixed record. `None` on clean EOF or a truncated record.
pub fn read_record<R: Read>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut length = [0u8; 4];
    if !read_exact_or_eof(reader, &mut length)? {
        return Ok(None);
    }
    let mut body = vec![0u8; u32::from_be_bytes(length) as usize];
    if !read_exact_or_eof(reader, &mut body)? {
        return Ok(None);
    }
    Ok(Some(body))
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

    fn from_file(output: File) -> Writer {
        Writer {
            stdout: Arc::new(Mutex::new(output)),
        }
    }

    /// Also sends a panic's message as an error LOG record before the usual
    /// report on stderr, which the Port does not read. Skipped while another
    /// thread is writing a record, which it would cut.
    pub fn log_panics(&self) {
        let stdout = Arc::clone(&self.stdout);
        let report = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let output = match stdout.try_lock() {
                Ok(output) => Some(output),
                Err(TryLockError::Poisoned(poisoned)) => Some(poisoned.into_inner()),
                Err(TryLockError::WouldBlock) => None,
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

/// The start of an RGB_FRAME record, which `width` x `height` pixels of
/// 8-bit red, green and blue follow, row-major.
pub fn rgb_frame_header(width: u16, height: u16, capture_ns: i64) -> [u8; 13] {
    image_header(TAG_RGB_FRAME, width, height, capture_ns)
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
    fn a_panic_is_sent_as_an_error_log_record() {
        let mut ends = [0; 2];
        // SAFETY: `ends` has room for the two descriptors.
        assert_eq!(unsafe { libc_pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both descriptors were just created and nothing else owns them.
        let (mut pipe_out, pipe_in) =
            unsafe { (File::from_raw_fd(ends[0]), File::from_raw_fd(ends[1])) };
        let writer = Writer::from_file(pipe_in);
        writer.log_panics();

        let panicked = std::panic::catch_unwind(|| panic!("no frame left"));
        let _ = std::panic::take_hook();

        assert!(panicked.is_err());
        drop(writer);
        let record = read_record(&mut pipe_out).unwrap().unwrap();
        assert_eq!(&record[..2], &[TAG_LOG, LogLevel::Error as u8]);
        let message = String::from_utf8(record[2..].to_vec()).unwrap();
        assert!(message.starts_with("panic: "), "{message}");
        assert!(message.contains("no frame left"), "{message}");
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
    fn rgb_frame_record_layout() {
        let got = [&rgb_frame_header(2, 1, -5)[..], &[1, 2, 3, 4, 5, 6]].concat();
        let want = [
            6, 2, 0, 1, 0, 0xfb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1, 2, 3, 4, 5, 6,
        ];
        assert_eq!(got, want);
    }

    #[test]
    fn read_record_returns_none_on_eof() {
        assert_eq!(read_record(&mut &[][..]).unwrap(), None);
    }

    #[test]
    fn read_record_returns_none_on_truncated_body() {
        let mut input: &[u8] = &[0, 0, 0, 10, 1, 2, 3, 4];
        assert_eq!(read_record(&mut input).unwrap(), None);
    }

    #[test]
    fn read_record_reads_a_record() {
        let mut input: &[u8] = &[0, 0, 0, 2, 9, 8, 7];
        assert_eq!(read_record(&mut input).unwrap(), Some(vec![9, 8]));
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
