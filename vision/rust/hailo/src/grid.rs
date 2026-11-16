//! A segmentation model's class ids, at its input's size or a whole fraction of it, kept as
//! one id per cell.

/// The side, in output pixels, of a `cell_pixels` × `cell_pixels` cell of the input, for an
/// output of class ids `output` (width, height) of an input `input`: the output is the input
/// divided by a whole factor on both sides, which divides `cell_pixels`.
pub fn output_stride(
    input: (usize, usize),
    output: (usize, usize),
    cell_pixels: usize,
) -> Result<usize, String> {
    let refused = || {
        Err(format!(
            "a {}x{} output of class ids for a {}x{} input, which {cell_pixels}-pixel cells do not fall on",
            output.0, output.1, input.0, input.1
        ))
    };
    if output.0 == 0 || output.1 == 0 || !input.0.is_multiple_of(output.0) {
        return refused();
    }
    let factor = input.0 / output.0;
    if output.1 * factor != input.1 || !cell_pixels.is_multiple_of(factor) {
        return refused();
    }
    Ok(cell_pixels / factor)
}

/// The class at the centre of each `stride` × `stride` cell of `labels`, a `width` × `height`
/// grid of class ids, row by row: `(width / stride, height / stride, cells)`, the cells past
/// the last whole one dropped.
pub fn cell_labels(
    labels: &[u8],
    width: usize,
    height: usize,
    stride: usize,
) -> (usize, usize, Vec<u8>) {
    let (columns, rows) = (width / stride, height / stride);
    let centre = stride / 2;
    let mut cells = Vec::with_capacity(columns * rows);
    for row in 0..rows {
        let line = &labels[(row * stride + centre) * width..];
        cells.extend((0..columns).map(|column| line[column * stride + centre]));
    }
    (columns, rows, cells)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_output_at_the_inputs_size_keeps_a_cells_pixels() {
        assert_eq!(output_stride((1152, 576), (1152, 576), 8), Ok(8));
    }

    #[test]
    fn an_output_at_a_fraction_of_the_input_keeps_fewer() {
        assert_eq!(output_stride((1152, 576), (144, 72), 8), Ok(1));
        assert_eq!(output_stride((1152, 576), (288, 144), 8), Ok(2));
    }

    #[test]
    fn refuses_an_output_the_cells_do_not_fall_on() {
        // Not a whole fraction, or not the same on both sides.
        assert!(output_stride((1152, 576), (1000, 500), 8).is_err());
        assert!(output_stride((1152, 576), (144, 144), 8).is_err());
        // Cells of 8 pixels on a 1/16 grid.
        assert!(output_stride((1152, 576), (72, 36), 8).is_err());
        // A larger output than its input.
        assert!(output_stride((576, 288), (1152, 576), 8).is_err());
    }

    #[test]
    fn keeps_the_class_at_each_cells_centre() {
        // 4 × 4 pixels: class = 10 × row + column.
        let labels: Vec<u8> = (0..4)
            .flat_map(|row| (0..4).map(move |column| 10 * row + column))
            .collect();
        assert_eq!(cell_labels(&labels, 4, 4, 2), (2, 2, vec![11, 13, 31, 33]));
    }

    #[test]
    fn drops_the_pixels_past_the_last_whole_cell() {
        let labels = vec![7u8; 5 * 3];
        assert_eq!(cell_labels(&labels, 5, 3, 2), (2, 1, vec![7, 7]));
    }

    #[test]
    fn a_stride_of_one_keeps_every_pixel() {
        let labels: Vec<u8> = (0..6).collect();
        assert_eq!(cell_labels(&labels, 3, 2, 1), (3, 2, labels));
    }
}
