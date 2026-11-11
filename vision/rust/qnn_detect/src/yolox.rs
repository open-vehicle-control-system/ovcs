//! YOLOX's quantised outputs to detections.

use detection::letterbox::{to_caller, Letterbox};
use detection::nms::suppress;
use detection::protocol::Detection;

/// The model's input side, in pixels.
pub const MODEL_SIZE: i32 = 640;
/// Candidate boxes YOLOX scores at a 640 input: 80², 40² and 20² cells.
pub const ANCHORS: usize = 8400;

/// An 8-bit tensor's quantisation: a value `q` stands for `(q - zero_point) × scale`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quantisation {
    pub scale: f32,
    pub zero_point: i32,
}

impl Quantisation {
    pub fn real(self, q: u8) -> f32 {
        (i32::from(q) - self.zero_point) as f32 * self.scale
    }
}

/// The graph's outputs for one image: `[x0, y0, x1, y1]` per anchor in model
/// pixels, a score and a class per anchor.
pub struct Outputs<'a> {
    pub boxes: &'a [u8],
    pub box_quantisation: Quantisation,
    pub scores: &'a [u8],
    pub score_quantisation: Quantisation,
    pub classes: &'a [u8],
}

/// The detections scoring above `threshold`, suppressed at `iou` per class
/// and mapped back through `letterbox` into the caller's pixels.
pub fn decode(
    outputs: &Outputs,
    threshold: f32,
    iou: f32,
    letterbox: &Letterbox,
) -> Vec<Detection> {
    let candidates = outputs
        .scores
        .iter()
        .enumerate()
        .filter_map(|(anchor, &q)| {
            let score = outputs.score_quantisation.real(q);
            (score > threshold).then(|| {
                let corner =
                    |k: usize| outputs.box_quantisation.real(outputs.boxes[anchor * 4 + k]);
                let [x0, y0, x1, y1] =
                    to_caller(letterbox, [corner(0), corner(1), corner(2), corner(3)]);
                Detection {
                    class_id: u16::from(outputs.classes[anchor]),
                    score,
                    x0,
                    y0,
                    x1,
                    y1,
                }
            })
        })
        .collect();
    suppress(candidates, iou)
}

#[cfg(test)]
mod tests {
    use super::*;
    use detection::letterbox::letterbox_for;

    const BOXES: Quantisation = Quantisation {
        scale: 4.4165,
        zero_point: 51,
    };
    const SCORES: Quantisation = Quantisation {
        scale: 0.0038126,
        zero_point: 0,
    };

    #[test]
    fn dequantises_boxes_with_the_tensor_parameters() {
        let real: Vec<f32> = [51u8, 51, 196, 196]
            .iter()
            .map(|&q| BOXES.real(q))
            .collect();
        for (value, expected) in real.iter().zip([0.0, 0.0, 640.4, 640.4]) {
            assert!((value - expected).abs() < 0.5, "{value} vs {expected}");
        }
    }

    #[test]
    fn keeps_scores_above_the_threshold_and_maps_back_through_the_letterbox() {
        let mut boxes = vec![51u8; ANCHORS * 4];
        let mut scores = vec![0u8; ANCHORS];
        let mut classes = vec![0u8; ANCHORS];
        // Two boxes in model pixels, far apart, scores 0.95 and 0.5; one more at 0.2.
        for (anchor, corners, score, class) in [
            (10, [100.0, 140.0, 200.0, 240.0], 0.95, 0),
            (20, [400.0, 300.0, 500.0, 400.0], 0.5, 2),
            (30, [300.0, 300.0, 350.0, 350.0], 0.2, 1),
        ] {
            for (k, value) in corners.iter().enumerate() {
                boxes[anchor * 4 + k] = (value / BOXES.scale + 51.0_f32).round() as u8;
            }
            scores[anchor] = (score / SCORES.scale).round() as u8;
            classes[anchor] = class;
        }
        let outputs = Outputs {
            boxes: &boxes,
            box_quantisation: BOXES,
            scores: &scores,
            score_quantisation: SCORES,
            classes: &classes,
        };
        let letterbox = letterbox_for(728, 544, 640);

        let detections = decode(&outputs, 0.4, 0.45, &letterbox);

        assert_eq!(detections.len(), 2);
        assert_eq!(detections[0].class_id, 0);
        assert!((detections[0].score - 0.95).abs() < 0.01);
        // 640 / 728 scales, and 640 - 544 * 640 / 728 = 161.8 rows pad, 80.9 above.
        let scale = 640.0 / 728.0;
        assert!(
            (detections[0].x0 - 100.0 / scale).abs() < 3.0,
            "{:?}",
            detections[0]
        );
        assert!(
            (detections[0].y0 - (140.0 - 81.0) / scale).abs() < 3.0,
            "{:?}",
            detections[0]
        );
        assert!(detections.iter().all(|d| d.x1 <= 728.0 && d.y1 <= 544.0));
        assert_eq!(detections[1].class_id, 2);
    }
}
