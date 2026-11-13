//! Port records: a detect request in, a detections record out. Scalars are little-endian.
//!
//! Request: u8 tag 1, u32 sequence, u16 width, u16 height, u8 channels (1 grey, 3 RGB), pixels.
//! Detections: u8 tag 1, u32 sequence, u16 count, count × {u16 class_id, f32 score, x0, y0,
//! x1, y1}, then a u32 inference time in µs when the frame was inferred, absent otherwise.

const TAG_DETECT: u8 = 1;
const TAG_DETECTIONS: u8 = 1;
/// tag, sequence, width, height, channels
const DETECT_HEADER_BYTES: usize = 1 + 4 + 2 + 2 + 1;
/// class_id, score, x0, y0, x1, y1
const DETECTION_BYTES: usize = 2 + 5 * 4;

#[derive(Debug, PartialEq)]
pub struct Request<'a> {
    pub sequence: u32,
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

/// `None` for a short record or a wrong tag: with no sequence to answer, it is skipped.
pub fn parse_request(record: &[u8]) -> Option<Request<'_>> {
    if record.len() < DETECT_HEADER_BYTES || record[0] != TAG_DETECT {
        return None;
    }
    Some(Request {
        sequence: u32::from_le_bytes([record[1], record[2], record[3], record[4]]),
        width: u16::from_le_bytes([record[5], record[6]]),
        height: u16::from_le_bytes([record[7], record[8]]),
        channels: record[9],
        pixels: &record[DETECT_HEADER_BYTES..],
    })
}

impl Request<'_> {
    /// The channel count, the size and the pixel byte count; `Err` is the message to log
    /// before answering with no detections.
    pub fn check(&self) -> Result<(), String> {
        if self.channels != 1 && self.channels != 3 {
            return Err(format!(
                "frame {}: unsupported channel count {}",
                self.sequence, self.channels
            ));
        }
        if self.width == 0 || self.height == 0 {
            return Err(format!(
                "frame {}: a {}x{} image has no pixels",
                self.sequence, self.width, self.height
            ));
        }
        let expected = self.width as usize * self.height as usize * self.channels as usize;
        if self.pixels.len() != expected {
            return Err(format!(
                "frame {}: expected {} pixel bytes, got {}",
                self.sequence,
                expected,
                self.pixels.len()
            ));
        }
        Ok(())
    }
}

/// The detections record for `sequence`. `inference_micros`, the accelerator's time on
/// the frame, follows the last detection when the frame was inferred; a reader that stops
/// after `count` detections ignores it.
pub fn detections_record(
    sequence: u32,
    detections: &[Detection],
    inference_micros: Option<u32>,
) -> Vec<u8> {
    let mut record = Vec::with_capacity(1 + 4 + 2 + detections.len() * DETECTION_BYTES + 4);
    record.push(TAG_DETECTIONS);
    record.extend_from_slice(&sequence.to_le_bytes());
    record.extend_from_slice(&(detections.len() as u16).to_le_bytes());
    for detection in detections {
        record.extend_from_slice(&detection.class_id.to_le_bytes());
        for field in [
            detection.score,
            detection.x0,
            detection.y0,
            detection.x1,
            detection.y1,
        ] {
            record.extend_from_slice(&field.to_le_bytes());
        }
    }
    if let Some(micros) = inference_micros {
        record.extend_from_slice(&micros.to_le_bytes());
    }
    record
}

/// `micros` as a record's u32, saturated.
pub fn inference_micros(micros: u128) -> u32 {
    u32::try_from(micros).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(sequence: u32, width: u16, height: u16, channels: u8, pixels: &[u8]) -> Vec<u8> {
        let mut record = vec![1];
        record.extend_from_slice(&sequence.to_le_bytes());
        record.extend_from_slice(&width.to_le_bytes());
        record.extend_from_slice(&height.to_le_bytes());
        record.push(channels);
        record.extend_from_slice(pixels);
        record
    }

    #[test]
    fn parse_request_reads_header_and_pixels() {
        let record = request(0x01020304, 2, 1, 3, &[1, 2, 3, 4, 5, 6]);
        let got = parse_request(&record).unwrap();
        assert_eq!(
            got,
            Request {
                sequence: 0x01020304,
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
        let record = request(7, 0, 0, 1, &[]);
        assert!(parse_request(&record).is_some());
        assert_eq!(parse_request(&record[..9]), None);
        assert_eq!(parse_request(&[]), None);
    }

    #[test]
    fn parse_request_rejects_wrong_tag() {
        let mut record = request(7, 1, 1, 1, &[0]);
        record[0] = 2;
        assert_eq!(parse_request(&record), None);
    }

    #[test]
    fn check_rejects_bad_channels_and_sizes() {
        let record = request(9, 1, 1, 2, &[0, 0]);
        assert_eq!(
            parse_request(&record).unwrap().check(),
            Err("frame 9: unsupported channel count 2".to_string())
        );
        let record = request(9, 2, 2, 1, &[0, 0, 0]);
        assert_eq!(
            parse_request(&record).unwrap().check(),
            Err("frame 9: expected 4 pixel bytes, got 3".to_string())
        );
    }

    #[test]
    fn check_rejects_an_image_without_pixels() {
        for (width, height) in [(0, 0), (0, 4), (4, 0)] {
            let record = request(9, width, height, 3, &[]);
            assert_eq!(
                parse_request(&record).unwrap().check(),
                Err(format!("frame 9: a {width}x{height} image has no pixels"))
            );
        }
    }

    #[test]
    fn detections_record_matches_cpp_layout() {
        let detection = Detection {
            class_id: 0x0102,
            score: 0.5,
            x0: 1.0,
            y0: 2.0,
            x1: 3.0,
            y1: 4.0,
        };
        let got = detections_record(0x0a0b0c0d, &[detection, detection], None);
        let mut want = vec![1, 0x0d, 0x0c, 0x0b, 0x0a, 2, 0];
        for _ in 0..2 {
            want.extend_from_slice(&[0x02, 0x01]);
            for field in [0.5f32, 1.0, 2.0, 3.0, 4.0] {
                want.extend_from_slice(&field.to_le_bytes());
            }
        }
        assert_eq!(got, want);
        assert_eq!(got.len(), 7 + 2 * DETECTION_BYTES);
    }

    #[test]
    fn empty_detections_record() {
        assert_eq!(detections_record(5, &[], None), [1, 5, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn inference_time_follows_the_detections() {
        let detection = Detection {
            class_id: 3,
            score: 0.5,
            x0: 1.0,
            y0: 2.0,
            x1: 3.0,
            y1: 4.0,
        };
        let without = detections_record(5, &[detection], None);
        let got = detections_record(5, &[detection], Some(0x01020304));
        assert_eq!(got[..without.len()], without[..]);
        assert_eq!(got[without.len()..], [0x04, 0x03, 0x02, 0x01]);
        assert_eq!(
            detections_record(5, &[], Some(7)),
            [1, 5, 0, 0, 0, 0, 0, 7, 0, 0, 0]
        );
    }

    #[test]
    fn inference_micros_saturates() {
        assert_eq!(inference_micros(12_345), 12_345);
        assert_eq!(inference_micros(u128::from(u32::MAX) + 1), u32::MAX);
    }
}
