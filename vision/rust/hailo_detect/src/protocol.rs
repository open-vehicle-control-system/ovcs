//! Port records: a detect request in, a detections record out. Scalars are little-endian.

const TAG_DETECT: u8 = 1;
const TAG_DETECTIONS: u8 = 1;
/// tag, seq, width, height, channels
const DETECT_HEADER_BYTES: usize = 1 + 4 + 2 + 2 + 1;
/// class_id, score, x0, y0, x1, y1
const DETECTION_BYTES: usize = 2 + 5 * 4;

#[derive(Debug, PartialEq)]
pub struct Request<'a> {
    pub seq: u32,
    pub width: u16,
    pub height: u16,
    pub channels: u8,
    pub pixels: &'a [u8],
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Detection {
    pub class_id: u16,
    pub score: f32,
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
}

/// `None` for a short record or a wrong tag, which are skipped without a log.
pub fn parse_request(rec: &[u8]) -> Option<Request<'_>> {
    if rec.len() < DETECT_HEADER_BYTES || rec[0] != TAG_DETECT {
        return None;
    }
    Some(Request {
        seq: u32::from_le_bytes([rec[1], rec[2], rec[3], rec[4]]),
        width: u16::from_le_bytes([rec[5], rec[6]]),
        height: u16::from_le_bytes([rec[7], rec[8]]),
        channels: rec[9],
        pixels: &rec[DETECT_HEADER_BYTES..],
    })
}

impl Request<'_> {
    /// The channel count and pixel byte count; `Err` is the message to log before skipping.
    pub fn check(&self) -> Result<(), String> {
        if self.channels != 1 && self.channels != 3 {
            return Err(format!(
                "frame {}: unsupported channel count {}",
                self.seq, self.channels
            ));
        }
        let expected = self.width as usize * self.height as usize * self.channels as usize;
        if self.pixels.len() != expected {
            return Err(format!(
                "frame {}: expected {} pixel bytes, got {}",
                self.seq,
                expected,
                self.pixels.len()
            ));
        }
        Ok(())
    }
}

pub fn detections_record(seq: u32, d: &[Detection]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + 4 + 2 + d.len() * DETECTION_BYTES);
    out.push(TAG_DETECTIONS);
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(&(d.len() as u16).to_le_bytes());
    for detection in d {
        out.extend_from_slice(&detection.class_id.to_le_bytes());
        for f in [
            detection.score,
            detection.x0,
            detection.y0,
            detection.x1,
            detection.y1,
        ] {
            out.extend_from_slice(&f.to_le_bytes());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(seq: u32, w: u16, h: u16, c: u8, pixels: &[u8]) -> Vec<u8> {
        let mut r = vec![1];
        r.extend_from_slice(&seq.to_le_bytes());
        r.extend_from_slice(&w.to_le_bytes());
        r.extend_from_slice(&h.to_le_bytes());
        r.push(c);
        r.extend_from_slice(pixels);
        r
    }

    #[test]
    fn parse_request_reads_header_and_pixels() {
        let rec = request(0x01020304, 2, 1, 3, &[1, 2, 3, 4, 5, 6]);
        let got = parse_request(&rec).unwrap();
        assert_eq!(
            got,
            Request {
                seq: 0x01020304,
                width: 2,
                height: 1,
                channels: 3,
                pixels: &[1, 2, 3, 4, 5, 6]
            }
        );
        assert_eq!(got.check(), Ok(()));
    }

    #[test]
    fn parse_request_rejects_short_record() {
        let rec = request(7, 0, 0, 1, &[]);
        assert!(parse_request(&rec).is_some());
        assert_eq!(parse_request(&rec[..9]), None);
        assert_eq!(parse_request(&[]), None);
    }

    #[test]
    fn parse_request_rejects_wrong_tag() {
        let mut rec = request(7, 1, 1, 1, &[0]);
        rec[0] = 2;
        assert_eq!(parse_request(&rec), None);
    }

    #[test]
    fn check_rejects_bad_channels_and_sizes() {
        let rec = request(9, 1, 1, 2, &[0, 0]);
        assert_eq!(
            parse_request(&rec).unwrap().check(),
            Err("frame 9: unsupported channel count 2".to_string())
        );
        let rec = request(9, 2, 2, 1, &[0, 0, 0]);
        assert_eq!(
            parse_request(&rec).unwrap().check(),
            Err("frame 9: expected 4 pixel bytes, got 3".to_string())
        );
    }

    #[test]
    fn detections_record_matches_cpp_layout() {
        let d = Detection {
            class_id: 0x0102,
            score: 0.5,
            x0: 1.0,
            y0: 2.0,
            x1: 3.0,
            y1: 4.0,
        };
        let got = detections_record(0x0a0b0c0d, &[d, d]);
        let mut want = vec![1, 0x0d, 0x0c, 0x0b, 0x0a, 2, 0];
        for _ in 0..2 {
            want.extend_from_slice(&[0x02, 0x01]);
            for f in [0.5f32, 1.0, 2.0, 3.0, 4.0] {
                want.extend_from_slice(&f.to_le_bytes());
            }
        }
        assert_eq!(got, want);
        assert_eq!(got.len(), 7 + 2 * DETECTION_BYTES);
    }

    #[test]
    fn empty_detections_record() {
        assert_eq!(detections_record(5, &[]), [1, 5, 0, 0, 0, 0, 0]);
    }
}
