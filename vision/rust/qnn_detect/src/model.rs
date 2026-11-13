//! The model's shape check: one 640x640 uint8 RGB image of pixel values in, unquantised or
//! quantised with a scale of 1/255 and an offset of 0, and YOLOX's three uint8 outputs,
//! `boxes` and `scores` quantised, `class_idx` a class per anchor.

use qnn::Tensor;

use crate::yolox::{Quantisation, ANCHORS, MODEL_SIZE};

/// Where the outputs the decoding reads are among the graph's, and how two are quantised.
#[derive(Debug, PartialEq)]
pub struct Layout {
    pub boxes: usize,
    pub box_quantisation: Quantisation,
    pub scores: usize,
    pub score_quantisation: Quantisation,
    pub classes: usize,
}

/// The model's layout, or the message naming the input or output it cannot run on.
pub fn layout(inputs: &[Tensor], outputs: &[Tensor]) -> Result<Layout, String> {
    let input_bytes = (MODEL_SIZE * MODEL_SIZE * 3) as usize;
    match inputs {
        [input] if input.bytes == input_bytes && input.unsigned_8bit => {
            input.check_takes_pixel_values()?
        }
        _ => {
            return Err(format!(
                "the model takes {} inputs, not one {MODEL_SIZE}x{MODEL_SIZE} uint8 RGB image",
                inputs.len()
            ))
        }
    }
    let boxes = output_index(outputs, "boxes", ANCHORS * 4)?;
    let scores = output_index(outputs, "scores", ANCHORS)?;
    Ok(Layout {
        boxes,
        box_quantisation: quantisation(&outputs[boxes])?,
        scores,
        score_quantisation: quantisation(&outputs[scores])?,
        classes: output_index(outputs, "class_idx", ANCHORS)?,
    })
}

/// The output named `name`, which must hold `bytes` unsigned bytes.
fn output_index(outputs: &[Tensor], name: &str, bytes: usize) -> Result<usize, String> {
    let index = (outputs.iter())
        .position(|tensor| tensor.name == name)
        .ok_or_else(|| format!("the model has no output {name}"))?;
    let output = &outputs[index];
    if output.bytes != bytes {
        return Err(format!(
            "output {name} holds {} bytes, not {bytes}",
            output.bytes
        ));
    }
    if !output.unsigned_8bit {
        return Err(format!("output {name} is not uint8"));
    }
    Ok(index)
}

fn quantisation(output: &Tensor) -> Result<Quantisation, String> {
    let (scale, offset) = output
        .scale_offset
        .ok_or_else(|| format!("output {} is not quantised", output.name))?;
    Ok(Quantisation {
        scale,
        zero_point: -offset,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tensor(name: &str, dimensions: &[u32], scale_offset: Option<(f32, i32)>) -> Tensor {
        Tensor {
            name: name.to_string(),
            dimensions: dimensions.to_vec(),
            scale_offset,
            unsigned_8bit: true,
            bytes: dimensions.iter().map(|&size| size as usize).product(),
        }
    }

    fn image() -> Tensor {
        tensor("image", &[1, 640, 640, 3], Some((1.0 / 255.0, 0)))
    }

    fn yolox_outputs() -> [Tensor; 3] {
        [
            tensor("class_idx", &[1, 8400], None),
            tensor("boxes", &[1, 8400, 4], Some((2.5, -3))),
            tensor("scores", &[1, 8400], Some((0.004, 0))),
        ]
    }

    #[test]
    fn yolox_outputs_are_found_by_name_with_their_quantisation() {
        assert_eq!(
            layout(&[image()], &yolox_outputs()),
            Ok(Layout {
                boxes: 1,
                box_quantisation: Quantisation {
                    scale: 2.5,
                    zero_point: 3
                },
                scores: 2,
                score_quantisation: Quantisation {
                    scale: 0.004,
                    zero_point: 0
                },
                classes: 0,
            })
        );
    }

    #[test]
    fn an_output_of_signed_bytes_is_refused() {
        for name in ["boxes", "scores", "class_idx"] {
            let mut outputs = yolox_outputs();
            let signed = outputs.iter_mut().find(|output| output.name == name);
            signed.unwrap().unsigned_8bit = false;
            assert_eq!(
                layout(&[image()], &outputs),
                Err(format!("output {name} is not uint8"))
            );
        }
    }

    #[test]
    fn an_input_other_than_uint8_pixel_values_is_refused() {
        let signed = Tensor {
            unsigned_8bit: false,
            ..image()
        };
        assert_eq!(
            layout(&[signed], &yolox_outputs()),
            Err("the model takes 1 inputs, not one 640x640 uint8 RGB image".to_string())
        );
        let offset = Tensor {
            scale_offset: Some((1.0 / 255.0, -128)),
            ..image()
        };
        let refused = layout(&[offset], &yolox_outputs()).unwrap_err();
        assert!(refused.contains("an offset of -128"), "{refused}");
        let unquantised = Tensor {
            scale_offset: None,
            ..image()
        };
        assert!(layout(&[unquantised], &yolox_outputs()).is_ok());
    }

    #[test]
    fn a_missing_misnamed_or_unquantised_output_is_named() {
        assert_eq!(
            layout(&[image()], &yolox_outputs()[..2]),
            Err("the model has no output scores".to_string())
        );
        let mut outputs = yolox_outputs();
        outputs[1] = tensor("boxes", &[1, 8400, 2], Some((2.5, -3)));
        assert_eq!(
            layout(&[image()], &outputs),
            Err("output boxes holds 16800 bytes, not 33600".to_string())
        );
        let mut outputs = yolox_outputs();
        outputs[2].scale_offset = None;
        assert_eq!(
            layout(&[image()], &outputs),
            Err("output scores is not quantised".to_string())
        );
    }
}
