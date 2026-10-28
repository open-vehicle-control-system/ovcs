//! `{:packet, 4}` framing for the Port binaries: a big-endian length prefix per
//! record. Record scalars are little-endian and match the Elixir parser in
//! `VisionCore.Camera.LibCamera` byte for byte.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, RawFd};
use std::sync::Mutex;

const TAG_FRAME: u8 = 1;
const TAG_LOG: u8 = 2;
const TAG_METADATA: u8 = 3;

pub const METADATA_FIELDS: usize = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogLevel {
    Info = 0,
    Warning = 1,
    Error = 2,
}

extern "C" {
    fn dup(fd: RawFd) -> RawFd;
    fn dup2(old: RawFd, new: RawFd) -> RawFd;
}

/// Reads one length-prefixed record. `None` on clean EOF or a truncated record.
pub fn read_record<R: Read>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut length = [0u8; 4];
    if !read_exact_or_eof(r, &mut length)? {
        return Ok(None);
    }
    let mut body = vec![0u8; u32::from_be_bytes(length) as usize];
    if !read_exact_or_eof(r, &mut body)? {
        return Ok(None);
    }
    Ok(Some(body))
}

fn read_exact_or_eof<R: Read>(r: &mut R, buf: &mut [u8]) -> io::Result<bool> {
    match r.read_exact(buf) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(false),
        Err(e) => Err(e),
    }
}

/// Record output on the real stdout. Libraries that print to stdout would
/// corrupt the framing, so fd 1 is pointed at stderr.
pub struct Writer {
    out: Mutex<File>,
}

impl Writer {
    pub fn from_stdout_redirecting() -> io::Result<Writer> {
        // SAFETY: plain fd syscalls; the dup'd fd is owned by the returned File.
        unsafe {
            let saved = dup(1);
            if saved < 0 {
                return Err(io::Error::last_os_error());
            }
            let out = File::from_raw_fd(saved);
            if dup2(2, 1) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Writer {
                out: Mutex::new(out),
            })
        }
    }

    /// Writes one record. Safe to call from several threads.
    pub fn write_record(&self, data: &[u8]) -> io::Result<()> {
        let length = u32::try_from(data.len())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "record too large"))?;
        let mut packet = Vec::with_capacity(4 + data.len());
        packet.extend_from_slice(&length.to_be_bytes());
        packet.extend_from_slice(data);
        let mut out = self.out.lock().unwrap_or_else(|e| e.into_inner());
        out.write_all(&packet)?;
        out.flush()
    }
}

pub fn frame_record(width: u16, height: u16, capture_ns: i64, jpeg: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(17 + jpeg.len());
    out.push(TAG_FRAME);
    out.extend_from_slice(&width.to_le_bytes());
    out.extend_from_slice(&height.to_le_bytes());
    out.extend_from_slice(&capture_ns.to_le_bytes());
    out.extend_from_slice(&(jpeg.len() as u32).to_le_bytes());
    out.extend_from_slice(jpeg);
    out
}

pub fn log_record(level: LogLevel, message: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + message.len());
    out.push(TAG_LOG);
    out.push(level as u8);
    out.extend_from_slice(message.as_bytes());
    out
}

/// Bit i of `present` is set when `values[i]` was reported.
pub fn metadata_record(capture_ns: i64, present: u8, values: &[f64; METADATA_FIELDS]) -> Vec<u8> {
    let mut out = Vec::with_capacity(10 + 8 * METADATA_FIELDS);
    out.push(TAG_METADATA);
    out.push(present);
    out.extend_from_slice(&capture_ns.to_le_bytes());
    for v in values {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
