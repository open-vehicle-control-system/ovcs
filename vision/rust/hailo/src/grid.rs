//! A segmentation model's per-pixel class ids, at its input's size, kept as one id per cell.

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
