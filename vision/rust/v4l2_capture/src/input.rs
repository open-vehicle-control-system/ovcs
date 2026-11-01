//! The host's setting records on stdin.

use std::fs::File;
use std::io;
use std::os::fd::BorrowedFd;

/// `descriptor` as an unbuffered file: reading a record takes only that record
/// off the pipe, so `poll` still reports the next one. Rust's `Stdin` buffers,
/// and records it has already taken are out of `poll`'s sight.
pub fn unbuffered(descriptor: BorrowedFd<'_>) -> io::Result<File> {
    Ok(File::from(descriptor.try_clone_to_owned()?))
}

#[cfg(test)]
mod tests {
    use super::unbuffered;
    use std::fs::File;
    use std::io::Write;
    use std::os::fd::{AsFd, AsRawFd, FromRawFd};

    fn record(body: &[u8]) -> Vec<u8> {
        [&(body.len() as u32).to_be_bytes()[..], body].concat()
    }

    fn readable(file: &File) -> bool {
        let mut descriptor = libc::pollfd {
            fd: file.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one valid pollfd.
        unsafe { libc::poll(&mut descriptor, 1, 0) == 1 }
    }

    #[test]
    fn records_written_together_are_read_one_at_a_time_and_stay_visible_to_poll() {
        let mut ends = [0; 2];
        // SAFETY: `ends` has room for the two descriptors.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both descriptors were just created and nothing else owns them.
        let (pipe_out, mut pipe_in) =
            unsafe { (File::from_raw_fd(ends[0]), File::from_raw_fd(ends[1])) };
        let mut input = unbuffered(pipe_out.as_fd()).unwrap();
        pipe_in
            .write_all(&[record(b"exposure_us=10000"), record(b"gamma=2.0")].concat())
            .unwrap();

        assert_eq!(
            framing::read_record(&mut input).unwrap(),
            Some(b"exposure_us=10000".to_vec())
        );
        assert!(readable(&input));
        assert_eq!(
            framing::read_record(&mut input).unwrap(),
            Some(b"gamma=2.0".to_vec())
        );
        assert!(!readable(&input));
    }
}
