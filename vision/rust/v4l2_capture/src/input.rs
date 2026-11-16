//! The host's setting records on stdin.

use std::fs::File;
use std::io;
use std::os::fd::BorrowedFd;

/// The longest record taken from the host: a setting is a line of text.
pub const MAX_SETTING_BYTES: usize = 64 << 10;

/// `descriptor` as an unbuffered file: reading a record takes only that record
/// off the pipe, so `poll` still reports the next one. Rust's `Stdin` buffers,
/// and records it has already taken are out of `poll`'s sight.
pub fn unbuffered(descriptor: BorrowedFd<'_>) -> io::Result<File> {
    Ok(File::from(descriptor.try_clone_to_owned()?))
}

#[cfg(test)]
pub mod tests {
    use super::{unbuffered, MAX_SETTING_BYTES};
    use std::fs::File;
    use std::io::Write;
    use std::os::fd::{AsFd, AsRawFd, FromRawFd};
    use std::time::Duration;

    /// `body` framed as the host frames a record.
    pub fn record(body: &[u8]) -> Vec<u8> {
        [&(body.len() as u32).to_be_bytes()[..], body].concat()
    }

    /// A pipe's reading and writing ends.
    pub fn pipe() -> (File, File) {
        let mut ends = [0; 2];
        // SAFETY: `ends` has room for the two descriptors.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both descriptors were just created and nothing else owns them.
        unsafe { (File::from_raw_fd(ends[0]), File::from_raw_fd(ends[1])) }
    }

    fn readable(file: &File) -> bool {
        let mut descriptor = crate::pollfd(file.as_raw_fd());
        crate::poll(std::slice::from_mut(&mut descriptor), Duration::ZERO).unwrap();
        descriptor.revents & libc::POLLIN != 0
    }

    #[test]
    fn records_written_together_are_read_one_at_a_time_and_stay_visible_to_poll() {
        let (pipe_out, mut pipe_in) = pipe();
        let mut input = unbuffered(pipe_out.as_fd()).unwrap();
        pipe_in
            .write_all(&[record(b"exposure_us=10000"), record(b"gamma=2.0")].concat())
            .unwrap();

        assert_eq!(
            framing::read_record(&mut input, MAX_SETTING_BYTES).unwrap(),
            Some(b"exposure_us=10000".to_vec())
        );
        assert!(readable(&input));
        assert_eq!(
            framing::read_record(&mut input, MAX_SETTING_BYTES).unwrap(),
            Some(b"gamma=2.0".to_vec())
        );
        assert!(!readable(&input));
    }
}
