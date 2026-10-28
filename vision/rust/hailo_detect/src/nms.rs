//! Decoding of HailoRT's `HAILO_NMS_BY_CLASS` output.

use crate::letterbox::{to_caller, Letterbox};
use crate::protocol::Detection;

/// y_min, x_min, y_max, x_max, score
pub const FLOATS_PER_BOX: usize = 5;

/// Per class, a float count then that many boxes ordered y_min, x_min, y_max, x_max, score,
/// normalised to the padded model input. Boxes come back in caller pixels, clamped to the frame.
pub fn decode_nms_by_class(
    output: &[f32],
    class_count: usize,
    source_width: i32,
    source_height: i32,
    b: &Letterbox,
    model: i32,
    score_threshold: f32,
) -> Vec<Detection> {
    let mut detections = Vec::new();
    let mut offset = 0;
    let model = model as f32;
    let (width, height) = (source_width as f32, source_height as f32);

    for class_id in 0..class_count {
        if offset >= output.len() {
            break;
        }
        let count = output[offset] as usize;
        offset += 1;
        if count == 0 {
            continue;
        }
        let end = match class_end(offset, count) {
            Some(end) if end <= output.len() => end,
            _ => break,
        };

        for bbox in output[offset..end].chunks_exact(FLOATS_PER_BOX) {
            let score = bbox[4];
            if score < score_threshold {
                continue;
            }
            let [x0, y0, x1, y1] = to_caller(
                b,
                [
                    bbox[1] * model,
                    bbox[0] * model,
                    bbox[3] * model,
                    bbox[2] * model,
                ],
            );
            // A box may extend into the padding when an object is cut off at the frame edge.
            let detection = Detection {
                class_id: class_id as u16,
                score,
                x0: x0.max(0.0).min(width),
                y0: y0.max(0.0).min(height),
                x1: x1.max(0.0).min(width),
                y1: y1.max(0.0).min(height),
            };
            if detection.x1 > detection.x0 && detection.y1 > detection.y0 {
                detections.push(detection);
            }
        }
        offset = end;
    }

    detections
}

/// End of a class's boxes that start at `offset`; `None` when a garbage count overflows.
pub fn class_end(offset: usize, count: usize) -> Option<usize> {
    count.checked_mul(FLOATS_PER_BOX)?.checked_add(offset)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::letterbox::letterbox_for;

    fn assert_near(d: &Detection, want: [f32; 4]) {
        let got = [d.x0, d.y0, d.x1, d.y1];
        for (g, w) in got.iter().zip(want) {
            assert!((g - w).abs() < 1e-3, "{got:?} != {want:?}");
        }
    }

    #[test]
    fn decodes_by_class_with_swapped_axes_threshold_and_clamp() {
        // 480x270 into 640: scale 4/3, offset_y 140.
        let b = letterbox_for(480, 270, 640);
        let output = [
            // class 0: one box, below threshold
            1.0, 0.5, 0.5, 0.6, 0.6, 0.3, //
            // class 1: none
            0.0, //
            // class 2: two boxes; the second runs into the bottom padding
            2.0, 0.5, 0.25, 0.625, 0.5, 0.9, //
            0.5, 0.0, 1.0, 0.5, 0.4,
        ];
        let got = decode_nms_by_class(&output, 3, 480, 270, &b, 640, 0.4);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].class_id, 2);
        assert_eq!(got[0].score, 0.9);
        assert_near(&got[0], [120.0, 135.0, 240.0, 195.0]);
        assert_near(&got[1], [0.0, 135.0, 240.0, 270.0]);
    }

    #[test]
    fn drops_degenerate_boxes() {
        let b = letterbox_for(480, 270, 640);
        // Entirely inside the top padding: clamps to zero height.
        let output = [1.0, 0.0, 0.1, 0.1, 0.2, 0.9];
        assert!(decode_nms_by_class(&output, 1, 480, 270, &b, 640, 0.4).is_empty());
    }

    #[test]
    fn stops_on_a_count_that_overflows() {
        let b = letterbox_for(480, 270, 640);
        let output = [1.0e30, 0.5, 0.25, 0.625, 0.5, 0.9];
        assert!(decode_nms_by_class(&output, 2, 480, 270, &b, 640, 0.4).is_empty());
        assert_eq!(class_end(1, usize::MAX), None);
        assert_eq!(class_end(usize::MAX, 1), None);
    }

    #[test]
    fn stops_on_truncated_output() {
        let b = letterbox_for(480, 270, 640);
        let output = [1.0, 0.5, 0.25, 0.625, 0.5, 0.9, 3.0, 0.5];
        let got = decode_nms_by_class(&output, 5, 480, 270, &b, 640, 0.4);
        assert_eq!(got.len(), 1);
    }
}
