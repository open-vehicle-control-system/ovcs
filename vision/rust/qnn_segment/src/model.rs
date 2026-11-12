//! The model's shape check: one `[1, H, W, 3]` uint8 RGB image of pixel values in, unquantised
//! or quantised with a scale of 1/255 and an offset of 0, one `[1, H, W, C]` uint8 score map out,
//! C scores per cell, C the classes the pipeline names.

/// How far a pixel value's scale times 255 may be from 1.
const PIXEL_SCALE_TOLERANCE: f32 = 1e-2;

use qnn::Tensor;

/// The model's input image and output grid sizes, and its classes.
#[derive(Debug, PartialEq)]
pub struct Geometry {
    pub input_width: usize,
    pub input_height: usize,
    pub output_width: u16,
    pub output_height: u16,
    pub classes: usize,
}

/// The model's geometry, or the message naming the input or output it cannot run on, its
/// output scoring other than `expected_classes` classes.
pub fn geometry(
    inputs: &[Tensor],
    outputs: &[Tensor],
    expected_classes: usize,
) -> Result<Geometry, String> {
    let ([input], [output]) = (inputs, outputs) else {
        return Err(format!(
            "the model takes {} inputs and gives {} outputs, not one image and one score map",
            inputs.len(),
            outputs.len()
        ));
    };
    let (input_height, input_width) = match (input.unsigned_8bit, &input.dimensions[..]) {
        (true, &[1, height, width, 3]) if height > 0 && width > 0 => (height, width),
        _ => {
            return Err(format!(
                "input {} is {}, not [1, H, W, 3] uint8",
                input.name,
                described(input)
            ))
        }
    };
    // Unquantised, the bytes are the values.
    if let Some((scale, offset)) = input
        .scale_offset
        .filter(|&(scale, offset)| !pixel_quantisation(scale, offset))
    {
        return Err(format!(
            "input {} has a scale of {scale} and an offset of {offset}, not a scale of 1/255 \
             and an offset of 0: it is fed pixel values from 0 to 255",
            input.name
        ));
    }
    let (output_height, output_width, classes) =
        match (output.unsigned_8bit, &output.dimensions[..]) {
            (true, &[1, height, width, classes])
                if (1..=256).contains(&classes) && height > 0 && width > 0 =>
            {
                match (u16::try_from(height), u16::try_from(width)) {
                    (Ok(height), Ok(width)) => Some((height, width, classes)),
                    _ => None,
                }
            }
            _ => None,
        }
        .ok_or_else(|| {
            format!(
                "output {} is {}, not [1, H, W, C] uint8, C at most 256",
                output.name,
                described(output)
            )
        })?;
    if classes as usize != expected_classes {
        return Err(format!(
            "output {} scores {classes} classes, not the {expected_classes} the pipeline's \
             labels name",
            output.name
        ));
    }
    if let Some((scale, _)) = output
        .scale_offset
        .filter(|&(scale, _)| scale.is_nan() || scale <= 0.0)
    {
        return Err(format!(
            "output {}'s scale is {scale}, not positive",
            output.name
        ));
    }
    Ok(Geometry {
        input_width: input_width as usize,
        input_height: input_height as usize,
        output_width,
        output_height,
        classes: classes as usize,
    })
}

/// Whether a quantisation reads the input's bytes as the pixel values they are: a scale of
/// 1/255 and an offset of 0.
fn pixel_quantisation(scale: f32, offset: i32) -> bool {
    offset == 0 && (scale * 255.0 - 1.0).abs() <= PIXEL_SCALE_TOLERANCE
}

/// The tensor's dimensions and whether its elements are uint8.
fn described(tensor: &Tensor) -> String {
    let element = if tensor.unsigned_8bit {
        "uint8"
    } else {
        "not uint8"
    };
    format!("{:?} {element}", tensor.dimensions)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PIXEL_SCALE: f32 = 1.0 / 255.0;
    const CITYSCAPES_CLASSES: usize = 19;

    fn tensor(name: &str, dimensions: &[u32], scale_offset: (f32, i32)) -> Tensor {
        Tensor {
            name: name.to_string(),
            dimensions: dimensions.to_vec(),
            scale_offset: Some(scale_offset),
            unsigned_8bit: true,
            bytes: dimensions.iter().map(|&size| size as usize).product(),
        }
    }

    fn image(dimensions: &[u32]) -> Tensor {
        tensor("image", dimensions, (PIXEL_SCALE, 0))
    }

    fn mask(dimensions: &[u32]) -> Tensor {
        tensor("mask", dimensions, (0.20315, -153))
    }

    fn checked(inputs: &[Tensor], outputs: &[Tensor]) -> Result<Geometry, String> {
        geometry(inputs, outputs, CITYSCAPES_CLASSES)
    }

    const FFNET_INPUT: [u32; 4] = [1, 512, 1024, 3];
    const FFNET_OUTPUT: [u32; 4] = [1, 128, 256, 19];

    #[test]
    fn ffnet_takes_a_1024_by_512_image_and_gives_a_256_by_128_grid_of_19_classes() {
        assert_eq!(
            checked(&[image(&FFNET_INPUT)], &[mask(&FFNET_OUTPUT)]),
            Ok(Geometry {
                input_width: 1024,
                input_height: 512,
                output_width: 256,
                output_height: 128,
                classes: 19,
            })
        );
    }

    #[test]
    fn width_and_height_come_from_their_own_dimensions() {
        let got = geometry(&[image(&[1, 30, 70, 3])], &[mask(&[1, 5, 11, 2])], 2).unwrap();
        assert_eq!(
            (
                got.input_width,
                got.input_height,
                got.output_width,
                got.output_height
            ),
            (70, 30, 11, 5)
        );
    }

    #[test]
    fn the_model_takes_one_image_and_gives_one_score_map() {
        let ffnet_image = || image(&FFNET_INPUT);
        let ffnet_mask = || mask(&FFNET_OUTPUT);
        let message =
            "the model takes 2 inputs and gives 1 outputs, not one image and one score map";
        assert_eq!(
            checked(&[ffnet_image(), ffnet_image()], &[ffnet_mask()]),
            Err(message.to_string())
        );
        assert!(checked(&[ffnet_image()], &[ffnet_mask(), ffnet_mask()]).is_err());
        assert!(checked(&[], &[ffnet_mask()]).is_err());
    }

    #[test]
    fn an_input_other_than_an_rgb_uint8_image_is_named() {
        let ffnet_mask = [mask(&FFNET_OUTPUT)];
        assert_eq!(
            checked(&[image(&[1, 512, 1024, 4])], &ffnet_mask),
            Err("input image is [1, 512, 1024, 4] uint8, not [1, H, W, 3] uint8".to_string())
        );
        assert!(checked(&[image(&[512, 1024, 3])], &ffnet_mask).is_err());
        assert!(checked(&[image(&[2, 512, 1024, 3])], &ffnet_mask).is_err());
        assert!(checked(&[image(&[1, 0, 1024, 3])], &ffnet_mask).is_err());
        let float = Tensor {
            unsigned_8bit: false,
            ..image(&FFNET_INPUT)
        };
        assert_eq!(
            checked(&[float], &ffnet_mask),
            Err("input image is [1, 512, 1024, 3] not uint8, not [1, H, W, 3] uint8".to_string())
        );
    }

    #[test]
    fn the_input_takes_pixel_values_unquantised_or_with_a_scale_of_1_over_255_and_no_offset() {
        let ffnet_mask = [mask(&FFNET_OUTPUT)];
        let quantised = |scale_offset| Tensor {
            scale_offset,
            ..image(&FFNET_INPUT)
        };
        for close in [
            PIXEL_SCALE * 1.009,
            PIXEL_SCALE * 0.991,
            0.003_921_57,
            0.0039,
        ] {
            assert!(
                checked(&[quantised(Some((close, 0)))], &ffnet_mask).is_ok(),
                "{close}"
            );
        }
        for far in [PIXEL_SCALE * 1.011, PIXEL_SCALE * 0.989, 1.0, 1.0 / 128.0] {
            assert!(
                checked(&[quantised(Some((far, 0)))], &ffnet_mask).is_err(),
                "{far}"
            );
        }
        assert_eq!(
            checked(&[quantised(Some((PIXEL_SCALE, -128)))], &ffnet_mask),
            Err(format!(
                "input image has a scale of {PIXEL_SCALE} and an offset of -128, not a scale of \
                 1/255 and an offset of 0: it is fed pixel values from 0 to 255"
            ))
        );
        assert!(checked(&[quantised(None)], &ffnet_mask).is_ok());
    }

    #[test]
    fn the_output_scores_the_classes_the_pipeline_names() {
        let twenty_classes = [mask(&[1, 128, 256, 20])];
        assert_eq!(
            geometry(&[image(&FFNET_INPUT)], &twenty_classes, 19),
            Err("output mask scores 20 classes, not the 19 the pipeline's labels name".to_string())
        );
        assert_eq!(
            geometry(&[image(&FFNET_INPUT)], &twenty_classes, 20).map(|got| got.classes),
            Ok(20)
        );
    }

    #[test]
    fn an_output_other_than_a_uint8_score_map_is_named() {
        let ffnet_image = [image(&FFNET_INPUT)];
        assert_eq!(
            checked(&ffnet_image, &[mask(&[1, 128, 256])]),
            Err(
                "output mask is [1, 128, 256] uint8, not [1, H, W, C] uint8, C at most 256"
                    .to_string()
            )
        );
        assert!(checked(&ffnet_image, &[mask(&[1, 128, 256, 257])]).is_err());
        assert!(checked(&ffnet_image, &[mask(&[1, 128, 256, 0])]).is_err());
        assert!(checked(&ffnet_image, &[mask(&[1, 128, 70_000, 19])]).is_err());
        let signed = Tensor {
            unsigned_8bit: false,
            ..mask(&FFNET_OUTPUT)
        };
        assert_eq!(
            checked(&ffnet_image, &[signed]),
            Err(
                "output mask is [1, 128, 256, 19] not uint8, not [1, H, W, C] uint8, C at most 256"
                    .to_string()
            )
        );
    }

    #[test]
    fn the_scores_scale_must_keep_their_order() {
        let ffnet_image = [image(&FFNET_INPUT)];
        let negative = Tensor {
            scale_offset: Some((-0.2, 0)),
            ..mask(&FFNET_OUTPUT)
        };
        assert_eq!(
            checked(&ffnet_image, &[negative]),
            Err("output mask's scale is -0.2, not positive".to_string())
        );
        let not_a_number = Tensor {
            scale_offset: Some((f32::NAN, 0)),
            ..mask(&FFNET_OUTPUT)
        };
        assert_eq!(
            checked(&ffnet_image, &[not_a_number]),
            Err("output mask's scale is NaN, not positive".to_string())
        );
        let plain = Tensor {
            scale_offset: None,
            ..mask(&FFNET_OUTPUT)
        };
        assert!(checked(&ffnet_image, &[plain]).is_ok());
    }
}
