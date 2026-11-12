//! The class of each cell of the model's output.

use detection::bands;

/// Each cell's class into `labels`: the index of the highest of its `classes` scores, the
/// lowest index on a tie. `scores` holds the cells' scores one cell after the other, as 8-bit
/// codes of a positive scale, which rank as the values they stand for. The cells are split
/// into up to `threads` bands.
pub fn argmax_into(scores: &[u8], classes: usize, labels: &mut [u8], threads: usize) {
    bands::in_row_bands(scores, classes, labels, 1, threads, |scores, labels| {
        argmax_cells(scores, classes, labels);
    });
}

fn argmax_cells(scores: &[u8], classes: usize, labels: &mut [u8]) {
    for (cell, label) in scores.chunks_exact(classes).zip(labels.iter_mut()) {
        let mut best = 0;
        for (class, &score) in cell.iter().enumerate().skip(1) {
            if score > cell[best] {
                best = class;
            }
        }
        *label = best as u8;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argmax(scores: &[u8], classes: usize) -> Vec<u8> {
        let mut labels = vec![u8::MAX; scores.len() / classes];
        argmax_into(scores, classes, &mut labels, 1);
        labels
    }

    #[test]
    fn each_cell_takes_its_highest_score() {
        assert_eq!(argmax(&[1, 9, 3, 7, 2, 0, 0, 0, 4], 3), [1, 0, 2]);
    }

    #[test]
    fn a_tie_goes_to_the_lowest_class() {
        assert_eq!(argmax(&[5, 9, 9, 2, 2, 2], 3), [1, 0]);
    }

    #[test]
    fn quantised_scores_rank_as_their_values() {
        let (scale, zero_point) = (0.20315f32, 153i32);
        let value = |q: u8| (i32::from(q) - zero_point) as f32 * scale;
        let cells: [[u8; 4]; 4] = [
            [152, 150, 140, 151],
            [100, 154, 153, 0],
            [255, 153, 254, 160],
            [10, 20, 30, 152],
        ];
        let by_value: Vec<u8> = cells
            .iter()
            .map(|cell| {
                (0..cell.len())
                    .reduce(|best, class| {
                        if value(cell[class]) > value(cell[best]) {
                            class
                        } else {
                            best
                        }
                    })
                    .unwrap() as u8
            })
            .collect();
        assert_eq!(by_value, [0, 1, 0, 3]);
        assert_eq!(argmax(cells.as_flattened(), 4), by_value);
    }

    #[test]
    fn nineteen_classes_give_up_to_class_18() {
        let mut scores = vec![0u8; 2 * 19];
        scores[18] = 200;
        scores[19 + 7] = 200;
        assert_eq!(argmax(&scores, 19), [18, 7]);
    }

    #[test]
    fn one_to_four_threads_give_the_same_labels() {
        let (cells, classes) = (37, 19);
        let mut state = 0x1234_5678u32;
        let scores: Vec<u8> = (0..cells * classes)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                (state >> 24) as u8
            })
            .collect();
        let labels = argmax(&scores, classes);
        for threads in 2..=4 {
            let mut threaded = vec![u8::MAX; cells];
            argmax_into(&scores, classes, &mut threaded, threads);
            assert_eq!(threaded, labels, "on {threads} threads");
        }
    }
}
