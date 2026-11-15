//! The parts of an `--output` flag the capture programs share: its size, the
//! index of the output it is made from, a JPEG's quality and the `:unsent`
//! suffix.

/// The most outputs a camera has: a record's output index is a byte.
pub const MAX_OUTPUTS: usize = 256;

/// The flag's value without its `:unsent` suffix, and whether the output is sent.
pub fn strip_unsent(value: &str) -> (&str, bool) {
    match value.strip_suffix(":unsent") {
        Some(made) => (made, false),
        None => (value, true),
    }
}

/// `<width>x<height>`, both above 0.
pub fn size(size: &str) -> Result<(u32, u32), String> {
    size.split_once('x')
        .and_then(|(width, height)| Some((width.parse().ok()?, height.parse().ok()?)))
        .filter(|&(width, height): &(u32, u32)| width > 0 && height > 0)
        .ok_or_else(|| format!("no size {size}"))
}

/// The index of the output another is made from.
pub fn index(index: &str) -> Result<usize, String> {
    index
        .parse()
        .map_err(|_| format!("no output index {index}"))
}

/// A JPEG's quality, 1 to 100.
pub fn jpeg_quality(quality: &str) -> Result<u8, String> {
    match quality.parse() {
        Ok(quality @ 1..=100) => Ok(quality),
        _ => Err(format!("a JPEG's quality is 1 to 100, got {quality}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unsent_suffix_is_stripped_once() {
        assert_eq!(strip_unsent("isp:1152x648:unsent"), ("isp:1152x648", false));
        assert_eq!(strip_unsent("isp:1152x648"), ("isp:1152x648", true));
        assert_eq!(
            strip_unsent("isp:1152x648:unsent:unsent"),
            ("isp:1152x648:unsent", false)
        );
    }

    #[test]
    fn a_size_is_two_positive_integers() {
        assert_eq!(size("1152x648"), Ok((1152, 648)));
        for refused in ["1152", "1152x", "x648", "0x648", "1152x0", "-1x648", "wxh"] {
            assert_eq!(
                size(refused),
                Err(format!("no size {refused}")),
                "{refused}"
            );
        }
    }

    #[test]
    fn an_index_is_a_non_negative_integer() {
        assert_eq!(index("3"), Ok(3));
        assert_eq!(index("x"), Err("no output index x".to_string()));
        assert_eq!(index("-1"), Err("no output index -1".to_string()));
    }

    #[test]
    fn a_jpeg_quality_is_1_to_100() {
        assert_eq!(jpeg_quality("1"), Ok(1));
        assert_eq!(jpeg_quality("100"), Ok(100));
        for refused in ["0", "101", "high", ""] {
            assert_eq!(
                jpeg_quality(refused),
                Err(format!("a JPEG's quality is 1 to 100, got {refused}"))
            );
        }
    }
}
