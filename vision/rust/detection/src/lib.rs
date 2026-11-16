//! What the vision Ports share: the detection Ports' record protocol, the letterbox between
//! the caller's image and the model's input, the bilinear resize under it, the
//! split of row-by-row work across threads, and box decoding.

pub mod bands;
pub mod bilinear;
pub mod letterbox;
pub mod nms;
pub mod protocol;

/// The lowest score a detection Port reports, from its command line: 0 to 1.
pub fn score_threshold(value: &str) -> Result<f32, String> {
    value
        .parse()
        .ok()
        .filter(|threshold: &f32| (0.0..=1.0).contains(threshold))
        .ok_or(format!("bad score threshold {value}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_score_threshold_is_a_number_from_0_to_1() {
        assert_eq!(score_threshold("0"), Ok(0.0));
        assert_eq!(score_threshold("0.4"), Ok(0.4));
        assert_eq!(score_threshold("1"), Ok(1.0));
        for refused in ["-0.1", "1.5", "NaN", "high", ""] {
            assert_eq!(
                score_threshold(refused),
                Err(format!("bad score threshold {refused}"))
            );
        }
    }
}
