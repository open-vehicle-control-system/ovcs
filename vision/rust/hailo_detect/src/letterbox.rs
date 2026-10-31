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

/// Fit `w`x`h` into a `model`-sized square, centred.
pub fn letterbox_for(w: i32, h: i32, model: i32) -> Letterbox {
    let scale = (model as f32 / w as f32).min(model as f32 / h as f32);
    let (scaled_width, scaled_height) = scaled_size(w, h, scale);
    Letterbox {
        scale,
        offset_x: (model - scaled_width) / 2,
        offset_y: (model - scaled_height) / 2,
    }
}

fn scaled_size(w: i32, h: i32, scale: f32) -> (i32, i32) {
    (
        (w as f32 * scale).round() as i32,
        (h as f32 * scale).round() as i32,
    )
}

/// Bilinear resize of `src` (gray or BGR) into `dst`, a `model`x`model` RGB buffer
/// padded with 114, YOLO's conventional letterbox fill.
pub fn letterbox_into(
    src: &[u8],
    w: i32,
    h: i32,
    channels: u8,
    dst: &mut [u8],
    model: i32,
    b: &Letterbox,
) {
    let model_px = model as usize;
    dst[..model_px * model_px * 3].fill(PAD_VALUE);

    let channels = channels as usize;
    let (scaled_width, scaled_height) = scaled_size(w, h, b.scale);
    let at = |row: i32, column: i32, c: usize| -> f32 {
        src[(row as usize * w as usize + column as usize) * channels + c] as f32
    };

    for y in 0..scaled_height {
        // Pixel-centre sampling keeps the image from creeping half a pixel up-left.
        let source_y = (y as f32 + 0.5) / b.scale - 0.5;
        let y0 = source_y.floor() as i32;
        let y_weight = source_y - y0 as f32;
        let top_row = y0.max(0).min(h - 1);
        let bottom_row = (y0 + 1).max(0).min(h - 1);

        for x in 0..scaled_width {
            let source_x = (x as f32 + 0.5) / b.scale - 0.5;
            let x0 = source_x.floor() as i32;
            let x_weight = source_x - x0 as f32;
            let left_column = x0.max(0).min(w - 1);
            let right_column = (x0 + 1).max(0).min(w - 1);

            let pixel = ((b.offset_y + y) as usize * model_px + (b.offset_x + x) as usize) * 3;

            for c in 0..channels {
                let top = at(top_row, left_column, c) * (1.0 - x_weight)
                    + at(top_row, right_column, c) * x_weight;
                let bottom = at(bottom_row, left_column, c) * (1.0 - x_weight)
                    + at(bottom_row, right_column, c) * x_weight;
                let sample = (top * (1.0 - y_weight) + bottom * y_weight).round() as u8;

                if channels == 1 {
                    dst[pixel..pixel + 3].fill(sample);
                } else {
                    dst[pixel + 2 - c] = sample;
                }
            }
        }
    }
}

/// Maps `[x0, y0, x1, y1]` in padded model pixels back to caller pixels.
pub fn to_caller(b: &Letterbox, model_box: [f32; 4]) -> [f32; 4] {
    let [x0, y0, x1, y1] = model_box;
    let x = |v: f32| (v - b.offset_x as f32) / b.scale;
    let y = |v: f32| (v - b.offset_y as f32) / b.scale;
    [x(x0), y(y0), x(x1), y(y1)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_near(got: [f32; 4], want: [f32; 4]) {
        for (g, w) in got.iter().zip(want) {
            assert!((g - w).abs() < 1e-3, "{got:?} != {want:?}");
        }
    }

    fn pixel(dst: &[u8], model: i32, x: i32, y: i32) -> [u8; 3] {
        let i = ((y * model + x) * 3) as usize;
        [dst[i], dst[i + 1], dst[i + 2]]
    }

    #[test]
    fn letterbox_for_480x270_into_640() {
        let b = letterbox_for(480, 270, 640);
        assert_eq!(b.scale, 640.0 / 480.0);
        assert_eq!(b.offset_x, 0);
        assert_eq!(b.offset_y, (640 - 360) / 2);
    }

    #[test]
    fn letterbox_for_portrait_pads_left_and_right() {
        let b = letterbox_for(100, 200, 64);
        assert_eq!(b.scale, 64.0 / 200.0);
        assert_eq!((b.offset_x, b.offset_y), (16, 0));
    }

    #[test]
    fn to_caller_inverts_letterbox() {
        let b = letterbox_for(480, 270, 640);
        assert_near(
            to_caller(&b, [0.0, 140.0, 640.0, 500.0]),
            [0.0, 0.0, 480.0, 270.0],
        );
        assert_near(
            to_caller(&b, [320.0, 320.0, 400.0, 400.0]),
            [240.0, 135.0, 300.0, 195.0],
        );
    }

    #[test]
    fn letterbox_into_pads_with_114() {
        let (w, h, model) = (4, 2, 8);
        let src = vec![200u8; (w * h * 3) as usize];
        let b = letterbox_for(w, h, model);
        assert_eq!((b.offset_x, b.offset_y), (0, 2));
        let mut dst = vec![0u8; (model * model * 3) as usize];
        letterbox_into(&src, w, h, 3, &mut dst, model, &b);
        for y in 0..model {
            let want = if (2..6).contains(&y) { 200 } else { 114 };
            for x in 0..model {
                assert_eq!(pixel(&dst, model, x, y), [want; 3], "at {x},{y}");
            }
        }
    }

    #[test]
    fn gray_is_replicated_to_rgb() {
        let src = [10u8, 10, 10, 10];
        let b = letterbox_for(2, 2, 2);
        let mut dst = [0u8; 12];
        letterbox_into(&src, 2, 2, 1, &mut dst, 2, &b);
        assert_eq!(dst, [10; 12]);
    }

    #[test]
    fn bgr_is_swapped_to_rgb() {
        let src = [1u8, 2, 3];
        let b = letterbox_for(1, 1, 1);
        let mut dst = [0u8; 3];
        letterbox_into(&src, 1, 1, 3, &mut dst, 1, &b);
        assert_eq!(dst, [3, 2, 1]);
    }

    #[test]
    fn bilinear_upscale_samples_pixel_centres() {
        // 2x1 gray [0, 100] upscaled x2: centres at -0.25, 0.25, 0.75, 1.25 source px.
        let src = [0u8, 100];
        let b = letterbox_for(2, 1, 4);
        assert_eq!((b.offset_x, b.offset_y), (0, 1));
        let mut dst = vec![0u8; 4 * 4 * 3];
        letterbox_into(&src, 2, 1, 1, &mut dst, 4, &b);
        let row: Vec<u8> = (0..4).map(|x| pixel(&dst, 4, x, 1)[0]).collect();
        assert_eq!(row, [0, 25, 75, 100]);
    }
}
