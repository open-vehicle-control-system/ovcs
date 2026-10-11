//! Reading a child process's output line by line.

use std::io::BufRead;

/// The lines of `reader` without their `\n` or `\r\n`, decoding invalid
/// UTF-8 lossily instead of stopping: a reader that stops early leaves the
/// child blocked on a full pipe.
pub fn lossy_lines<R: BufRead>(mut reader: R) -> impl Iterator<Item = String> {
    std::iter::from_fn(move || {
        let mut line = Vec::new();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => None,
            Ok(_) => {
                if line.ends_with(b"\n") {
                    line.pop();
                    if line.ends_with(b"\r") {
                        line.pop();
                    }
                }
                Some(String::from_utf8_lossy(&line).into_owned())
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::lossy_lines;

    #[test]
    fn invalid_utf8_does_not_stop_the_reader() {
        let input: &[u8] = b"cc: caf\xe9 not found\r\nnext line\nlast";
        let lines: Vec<String> = lossy_lines(input).collect();
        assert_eq!(
            lines,
            vec!["cc: caf\u{fffd} not found", "next line", "last"]
        );
    }
}
