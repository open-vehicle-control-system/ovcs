//! Letterbox from a caller frame into the model's square NHWC RGB input, and back.

const PAD_VALUE: u8 = 114;

/// Geometry that maps a caller frame into the model input, kept to invert it on the way out.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Letterbox {
    /// Caller px to model px.
    pub scale: f32,
    /// Left padding, in model px.
    pub offset_x: i32,
    /// Top padding, in model px.
    pub offset_y: i32,
}

/// Fit `width`x`height` into a `model`-sized square, centred.
pub fn letterbox_for(width: i32, height: i32, model: i32) -> Letterbox {
    let scale = (model as f32 / width as f32).min(model as f32 / height as f32);
    let (scaled_width, scaled_height) = scaled_size(width, height, scale);
    Letterbox {
        scale,
        offset_x: (model - scaled_width) / 2,
        offset_y: (model - scaled_height) / 2,
    }
}

fn scaled_size(width: i32, height: i32, scale: f32) -> (i32, i32) {
    (
        (width as f32 * scale).round() as i32,
        (height as f32 * scale).round() as i32,
    )
}

/// Bilinear resize of `source` (gray or BGR) into `destination`, a `model`x`model` RGB buffer
/// padded with 114, YOLO's conventional letterbox fill.
pub fn letterbox_into(
    source: &[u8],
    width: i32,
    height: i32,
    channels: u8,
    destination: &mut [u8],
    model: i32,
    letterbox: &Letterbox,
) {
    let model_px = model as usize;
    destination[..model_px * model_px * 3].fill(PAD_VALUE);

    let channels = channels as usize;
    let (scaled_width, scaled_height) = scaled_size(width, height, letterbox.scale);
    let at = |row: i32, column: i32, channel: usize| -> f32 {
        source[(row as usize * width as usize + column as usize) * channels + channel] as f32
    };

    for y in 0..scaled_height {
        // Pixel-centre sampling keeps the image from creeping half a pixel up-left.
        let source_y = (y as f32 + 0.5) / letterbox.scale - 0.5;
        let y0 = source_y.floor() as i32;
        let y_weight = source_y - y0 as f32;
        let top_row = y0.max(0).min(height - 1);
        let bottom_row = (y0 + 1).max(0).min(height - 1);

        for x in 0..scaled_width {
            let source_x = (x as f32 + 0.5) / letterbox.scale - 0.5;
            let x0 = source_x.floor() as i32;
            let x_weight = source_x - x0 as f32;
            let left_column = x0.max(0).min(width - 1);
            let right_column = (x0 + 1).max(0).min(width - 1);

            let pixel = ((letterbox.offset_y + y) as usize * model_px
                + (letterbox.offset_x + x) as usize)
                * 3;

            for channel in 0..channels {
                let top = at(top_row, left_column, channel) * (1.0 - x_weight)
                    + at(top_row, right_column, channel) * x_weight;
                let bottom = at(bottom_row, left_column, channel) * (1.0 - x_weight)
                    + at(bottom_row, right_column, channel) * x_weight;
                let sample = (top * (1.0 - y_weight) + bottom * y_weight).round() as u8;

                if channels == 1 {
                    destination[pixel..pixel + 3].fill(sample);
                } else {
                    destination[pixel + 2 - channel] = sample;
                }
            }
        }
    }
}

/// Maps `[x0, y0, x1, y1]` in padded model pixels back to caller pixels.
pub fn to_caller(letterbox: &Letterbox, model_box: [f32; 4]) -> [f32; 4] {
    let [x0, y0, x1, y1] = model_box;
    let caller_x = |model_x: f32| (model_x - letterbox.offset_x as f32) / letterbox.scale;
    let caller_y = |model_y: f32| (model_y - letterbox.offset_y as f32) / letterbox.scale;
    [caller_x(x0), caller_y(y0), caller_x(x1), caller_y(y1)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_near(got: [f32; 4], want: [f32; 4]) {
        for (got_coordinate, want_coordinate) in got.iter().zip(want) {
            assert!(
                (got_coordinate - want_coordinate).abs() < 1e-3,
                "{got:?} != {want:?}"
            );
        }
    }

    fn pixel(destination: &[u8], model: i32, x: i32, y: i32) -> [u8; 3] {
        let offset = ((y * model + x) * 3) as usize;
        [
            destination[offset],
            destination[offset + 1],
            destination[offset + 2],
        ]
    }

    #[test]
    fn letterbox_for_480x270_into_640() {
        let letterbox = letterbox_for(480, 270, 640);
        assert_eq!(letterbox.scale, 640.0 / 480.0);
        assert_eq!(letterbox.offset_x, 0);
        assert_eq!(letterbox.offset_y, (640 - 360) / 2);
    }

    #[test]
    fn letterbox_for_portrait_pads_left_and_right() {
        let letterbox = letterbox_for(100, 200, 64);
        assert_eq!(letterbox.scale, 64.0 / 200.0);
        assert_eq!((letterbox.offset_x, letterbox.offset_y), (16, 0));
    }

    #[test]
    fn to_caller_inverts_letterbox() {
        let letterbox = letterbox_for(480, 270, 640);
        assert_near(
            to_caller(&letterbox, [0.0, 140.0, 640.0, 500.0]),
            [0.0, 0.0, 480.0, 270.0],
        );
        assert_near(
            to_caller(&letterbox, [320.0, 320.0, 400.0, 400.0]),
            [240.0, 135.0, 300.0, 195.0],
        );
    }

    #[test]
    fn letterbox_into_pads_with_114() {
        let (width, height, model) = (4, 2, 8);
        let source = vec![200u8; (width * height * 3) as usize];
        let letterbox = letterbox_for(width, height, model);
        assert_eq!((letterbox.offset_x, letterbox.offset_y), (0, 2));
        let mut destination = vec![0u8; (model * model * 3) as usize];
        letterbox_into(
            &source,
            width,
            height,
            3,
            &mut destination,
            model,
            &letterbox,
        );
        for y in 0..model {
            let want = if (2..6).contains(&y) { 200 } else { 114 };
            for x in 0..model {
                assert_eq!(pixel(&destination, model, x, y), [want; 3], "at {x},{y}");
            }
        }
    }

    #[test]
    fn gray_is_replicated_to_rgb() {
        let source = [10u8, 10, 10, 10];
        let letterbox = letterbox_for(2, 2, 2);
        let mut destination = [0u8; 12];
        letterbox_into(&source, 2, 2, 1, &mut destination, 2, &letterbox);
        assert_eq!(destination, [10; 12]);
    }

    #[test]
    fn bgr_is_swapped_to_rgb() {
        let source = [1u8, 2, 3];
        let letterbox = letterbox_for(1, 1, 1);
        let mut destination = [0u8; 3];
        letterbox_into(&source, 1, 1, 3, &mut destination, 1, &letterbox);
        assert_eq!(destination, [3, 2, 1]);
    }

    #[test]
    fn bilinear_upscale_samples_pixel_centres() {
        // 2x1 gray [0, 100] upscaled x2: centres at -0.25, 0.25, 0.75, 1.25 source px.
        let source = [0u8, 100];
        let letterbox = letterbox_for(2, 1, 4);
        assert_eq!((letterbox.offset_x, letterbox.offset_y), (0, 1));
        let mut destination = vec![0u8; 4 * 4 * 3];
        letterbox_into(&source, 2, 1, 1, &mut destination, 4, &letterbox);
        let row: Vec<u8> = (0..4).map(|x| pixel(&destination, 4, x, 1)[0]).collect();
        assert_eq!(row, [0, 25, 75, 100]);
    }
}
