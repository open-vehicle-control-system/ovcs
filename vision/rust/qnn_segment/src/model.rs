//! The model's shape check: one `[1, H, W, 3]` uint8 RGB image in, one `[1, H, W, C]` uint8
//! score map out, C scores per cell.

/// A graph input or output as the shape check reads it.
pub struct Shape<'a> {
    pub name: &'a str,
    pub dimensions: &'a [u32],
    pub unsigned_8bit: bool,
    /// The quantisation's scale, when the tensor is quantised.
    pub scale: Option<f32>,
}

/// The model's input image and output grid sizes, and its classes.
#[derive(Debug, PartialEq)]
pub struct Geometry {
    pub input_width: usize,
    pub input_height: usize,
    pub output_width: u16,
    pub output_height: u16,
    pub classes: usize,
}

/// The model's geometry, or the message naming the input or output it cannot run on.
pub fn geometry(inputs: &[Shape], outputs: &[Shape]) -> Result<Geometry, String> {
    let ([input], [output]) = (inputs, outputs) else {
        return Err(format!(
            "the model takes {} inputs and gives {} outputs, not one image and one score map",
            inputs.len(),
            outputs.len()
        ));
    };
    let (input_height, input_width) = match (input.unsigned_8bit, input.dimensions) {
        (true, &[1, height, width, 3]) if height > 0 && width > 0 => (height, width),
        _ => {
            return Err(format!(
                "input {} is {}, not [1, H, W, 3] uint8",
                input.name,
                described(input)
            ))
        }
    };
    let (output_height, output_width, classes) = match (output.unsigned_8bit, output.dimensions) {
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
    if let Some(scale) = output.scale.filter(|&scale| scale.is_nan() || scale <= 0.0) {
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

/// The tensor's dimensions and whether its elements are uint8.
fn described(shape: &Shape) -> String {
    let element = if shape.unsigned_8bit {
        "uint8"
    } else {
        "not uint8"
    };
    format!("{:?} {element}", shape.dimensions)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shape(name: &'static str, dimensions: &'static [u32]) -> Shape<'static> {
        Shape {
            name,
            dimensions,
            unsigned_8bit: true,
            scale: Some(0.20315),
        }
    }

    const FFNET_INPUT: [u32; 4] = [1, 512, 1024, 3];
    const FFNET_OUTPUT: [u32; 4] = [1, 128, 256, 19];

    #[test]
    fn ffnet_takes_a_1024_by_512_image_and_gives_a_256_by_128_grid_of_19_classes() {
        assert_eq!(
            geometry(
                &[shape("image", &FFNET_INPUT)],
                &[shape("mask", &FFNET_OUTPUT)]
            ),
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
        let got = geometry(
            &[shape("image", &[1, 30, 70, 3])],
            &[shape("mask", &[1, 5, 11, 2])],
        )
        .unwrap();
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
        let image = || shape("image", &FFNET_INPUT);
        let mask = || shape("mask", &FFNET_OUTPUT);
        let message =
            "the model takes 2 inputs and gives 1 outputs, not one image and one score map";
        assert_eq!(
            geometry(&[image(), image()], &[mask()]),
            Err(message.to_string())
        );
        assert!(geometry(&[image()], &[mask(), mask()]).is_err());
        assert!(geometry(&[], &[mask()]).is_err());
    }

    #[test]
    fn an_input_other_than_an_rgb_uint8_image_is_named() {
        let mask = [shape("mask", &FFNET_OUTPUT)];
        assert_eq!(
            geometry(&[shape("image", &[1, 512, 1024, 4])], &mask),
            Err("input image is [1, 512, 1024, 4] uint8, not [1, H, W, 3] uint8".to_string())
        );
        assert!(geometry(&[shape("image", &[512, 1024, 3])], &mask).is_err());
        assert!(geometry(&[shape("image", &[2, 512, 1024, 3])], &mask).is_err());
        assert!(geometry(&[shape("image", &[1, 0, 1024, 3])], &mask).is_err());
        let float = Shape {
            unsigned_8bit: false,
            ..shape("image", &FFNET_INPUT)
        };
        assert_eq!(
            geometry(&[float], &mask),
            Err("input image is [1, 512, 1024, 3] not uint8, not [1, H, W, 3] uint8".to_string())
        );
    }

    #[test]
    fn an_output_other_than_a_uint8_score_map_is_named() {
        let image = [shape("image", &FFNET_INPUT)];
        assert_eq!(
            geometry(&image, &[shape("mask", &[1, 128, 256])]),
            Err(
                "output mask is [1, 128, 256] uint8, not [1, H, W, C] uint8, C at most 256"
                    .to_string()
            )
        );
        assert!(geometry(&image, &[shape("mask", &[1, 128, 256, 257])]).is_err());
        assert!(geometry(&image, &[shape("mask", &[1, 128, 256, 0])]).is_err());
        assert!(geometry(&image, &[shape("mask", &[1, 128, 70_000, 19])]).is_err());
        let signed = Shape {
            unsigned_8bit: false,
            ..shape("mask", &FFNET_OUTPUT)
        };
        assert_eq!(
            geometry(&image, &[signed]),
            Err(
                "output mask is [1, 128, 256, 19] not uint8, not [1, H, W, C] uint8, C at most 256"
                    .to_string()
            )
        );
    }

    #[test]
    fn the_scores_scale_must_keep_their_order() {
        let image = [shape("image", &FFNET_INPUT)];
        let negative = Shape {
            scale: Some(-0.2),
            ..shape("mask", &FFNET_OUTPUT)
        };
        assert_eq!(
            geometry(&image, &[negative]),
            Err("output mask's scale is -0.2, not positive".to_string())
        );
        let not_a_number = Shape {
            scale: Some(f32::NAN),
            ..shape("mask", &FFNET_OUTPUT)
        };
        assert_eq!(
            geometry(&image, &[not_a_number]),
            Err("output mask's scale is NaN, not positive".to_string())
        );
        let plain = Shape {
            scale: None,
            ..shape("mask", &FFNET_OUTPUT)
        };
        assert!(geometry(&image, &[plain]).is_ok());
    }
}
