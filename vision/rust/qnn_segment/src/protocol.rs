//! Port records: a segment request in, a labels record out. Scalars are little-endian.
//!
//! Request: u8 tag 7, u32 sequence, u16 width, u16 height, u8 channels (3, RGB), u16 band_top,
//! u16 band_height, pixels. The band is the image's rows `band_top..band_top + band_height`,
//! full width.
//! Labels: u8 tag 7, u32 sequence, u16 width, u16 height, width × height class ids (u8, row
//! by row), then a u32 inference time in µs when the band was inferred, absent otherwise. A
//! request that cannot be inferred is answered with a 0 × 0 label image.

const TAG_SEGMENT: u8 = 7;
const TAG_LABELS: u8 = 7;
/// tag, sequence, width, height, channels, band_top, band_height
const SEGMENT_HEADER_BYTES: usize = 1 + 4 + 2 + 2 + 1 + 2 + 2;

#[derive(Debug, PartialEq)]
pub struct Request<'a> {
    pub sequence: u32,
    pub width: u16,
    pub height: u16,
    pub channels: u8,
    pub band_top: u16,
    pub band_height: u16,
    pub pixels: &'a [u8],
}

/// `None` for a short record or a wrong tag: with no sequence to answer, it is skipped.
pub fn parse_request(record: &[u8]) -> Option<Request<'_>> {
    if record.len() < SEGMENT_HEADER_BYTES || record[0] != TAG_SEGMENT {
        return None;
    }
    let u16_at = |at: usize| u16::from_le_bytes([record[at], record[at + 1]]);
    Some(Request {
        sequence: u32::from_le_bytes([record[1], record[2], record[3], record[4]]),
        width: u16_at(5),
        height: u16_at(7),
        channels: record[9],
        band_top: u16_at(10),
        band_height: u16_at(12),
        pixels: &record[SEGMENT_HEADER_BYTES..],
    })
}

impl Request<'_> {
    /// The channel count, the pixel byte count and the band; `Err` is the message to log
    /// before answering with an empty label image.
    pub fn check(&self) -> Result<(), String> {
        if self.channels != 3 {
            return Err(format!(
                "frame {}: {} channels, not 3 (RGB)",
                self.sequence, self.channels
            ));
        }
        let expected = usize::from(self.width) * usize::from(self.height) * 3;
        if self.pixels.len() != expected {
            return Err(format!(
                "frame {}: expected {} pixel bytes, got {}",
                self.sequence,
                expected,
                self.pixels.len()
            ));
        }
        let band_end = u32::from(self.band_top) + u32::from(self.band_height);
        if self.width == 0 || self.band_height == 0 || band_end > u32::from(self.height) {
            return Err(format!(
                "frame {}: band of rows {}..{} in a {}x{} image",
                self.sequence, self.band_top, band_end, self.width, self.height
            ));
        }
        Ok(())
    }
}

/// The labels record for `sequence`: `labels`, `width` × `height` class ids, then
/// `inference_micros`, saturated to a u32, when the band was inferred.
pub fn labels_record(
    sequence: u32,
    width: u16,
    height: u16,
    labels: &[u8],
    inference_micros: Option<u64>,
) -> Vec<u8> {
    let mut record = Vec::with_capacity(1 + 4 + 2 + 2 + labels.len() + 4);
    record.push(TAG_LABELS);
    record.extend_from_slice(&sequence.to_le_bytes());
    record.extend_from_slice(&width.to_le_bytes());
    record.extend_from_slice(&height.to_le_bytes());
    record.extend_from_slice(labels);
    if let Some(micros) = inference_micros {
        let micros = detection::protocol::inference_micros(u128::from(micros));
        record.extend_from_slice(&micros.to_le_bytes());
    }
    record
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(
        sequence: u32,
        (width, height, channels): (u16, u16, u8),
        (band_top, band_height): (u16, u16),
        pixels: &[u8],
    ) -> Vec<u8> {
        let mut record = vec![7];
        record.extend_from_slice(&sequence.to_le_bytes());
        record.extend_from_slice(&width.to_le_bytes());
        record.extend_from_slice(&height.to_le_bytes());
        record.push(channels);
        record.extend_from_slice(&band_top.to_le_bytes());
        record.extend_from_slice(&band_height.to_le_bytes());
        record.extend_from_slice(pixels);
        record
    }

    #[test]
    fn parse_request_reads_the_header_the_band_and_the_pixels() {
        let pixels: Vec<u8> = (0..12).collect();
        let record = request(0x01020304, (2, 2, 3), (0x0102, 0x0304), &pixels);
        assert_eq!(
            parse_request(&record),
            Some(Request {
                sequence: 0x01020304,
                width: 2,
                height: 2,
                channels: 3,
                band_top: 0x0102,
                band_height: 0x0304,
                pixels: &pixels,
            })
        );
    }

    #[test]
    fn parse_request_rejects_a_short_record_and_a_wrong_tag() {
        let record = request(7, (0, 0, 3), (0, 0), &[]);
        assert!(parse_request(&record).is_some());
        assert_eq!(parse_request(&record[..SEGMENT_HEADER_BYTES - 1]), None);
        let mut detect = record.clone();
        detect[0] = 1;
        assert_eq!(parse_request(&detect), None);
    }

    fn checked(size: (u16, u16, u8), band: (u16, u16), pixel_bytes: usize) -> Result<(), String> {
        let record = request(9, size, band, &vec![0; pixel_bytes]);
        parse_request(&record).unwrap().check()
    }

    #[test]
    fn check_takes_an_rgb_image_and_a_band_inside_it() {
        assert_eq!(checked((4, 3, 3), (1, 2), 36), Ok(()));
        assert_eq!(checked((4, 3, 3), (0, 3), 36), Ok(()));
    }

    #[test]
    fn check_rejects_other_channel_counts_and_sizes() {
        assert_eq!(
            checked((4, 3, 1), (0, 2), 12),
            Err("frame 9: 1 channels, not 3 (RGB)".to_string())
        );
        assert_eq!(
            checked((4, 3, 3), (0, 2), 35),
            Err("frame 9: expected 36 pixel bytes, got 35".to_string())
        );
    }

    #[test]
    fn check_rejects_an_empty_band_or_one_past_the_image() {
        assert_eq!(
            checked((4, 3, 3), (1, 0), 36),
            Err("frame 9: band of rows 1..1 in a 4x3 image".to_string())
        );
        assert_eq!(
            checked((4, 3, 3), (2, 2), 36),
            Err("frame 9: band of rows 2..4 in a 4x3 image".to_string())
        );
        assert_eq!(
            checked((0, 3, 3), (0, 2), 0),
            Err("frame 9: band of rows 0..2 in a 0x3 image".to_string())
        );
    }

    #[test]
    fn labels_record_is_the_header_and_the_labels() {
        assert_eq!(
            labels_record(0x0a0b0c0d, 3, 2, &[0, 1, 2, 3, 4, 18], None),
            [7, 0x0d, 0x0c, 0x0b, 0x0a, 3, 0, 2, 0, 0, 1, 2, 3, 4, 18]
        );
    }

    #[test]
    fn inference_time_follows_the_labels() {
        assert_eq!(
            labels_record(5, 2, 1, &[1, 0], Some(0x01020304)),
            [7, 5, 0, 0, 0, 2, 0, 1, 0, 1, 0, 0x04, 0x03, 0x02, 0x01]
        );
        assert_eq!(
            labels_record(5, 1, 1, &[0], Some(u64::from(u32::MAX) + 1))[10..],
            [0xff; 4]
        );
    }

    #[test]
    fn an_unanswerable_request_gets_an_empty_label_image() {
        assert_eq!(
            labels_record(5, 0, 0, &[], None),
            [7, 5, 0, 0, 0, 0, 0, 0, 0]
        );
    }
}
