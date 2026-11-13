//! Row-by-row work split into horizontal bands, one thread a band.

/// Runs `work` over up to `threads` bands of whole rows of `input` and `output`, `input_row`
/// and `output_row` elements a row; the first band runs on the calling thread, each other on
/// a scoped thread of its own. `output` may hold more rows than `input`; those are left alone.
pub fn in_row_bands<I: Sync, O: Send>(
    input: &[I],
    input_row: usize,
    output: &mut [O],
    output_row: usize,
    threads: usize,
    work: impl Fn(&[I], &mut [O]) + Sync,
) {
    let rows = input.len().checked_div(input_row).unwrap_or(0);
    if rows == 0 || output_row == 0 {
        return;
    }
    let band = rows.div_ceil(threads.max(1));
    let mut bands = input
        .chunks(band * input_row)
        .zip(output.chunks_mut(band * output_row));
    let Some((first_input, first_output)) = bands.next() else {
        return;
    };
    let work = &work;
    std::thread::scope(|scope| {
        for (input, output) in bands {
            scope.spawn(move || work(input, output));
        }
        work(first_input, first_output);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each output row's sum of its input row, over `threads` threads.
    fn row_sums(input: &[u32], width: usize, rows: usize, threads: usize) -> Vec<u32> {
        let mut output = vec![0; rows];
        in_row_bands(input, width, &mut output, 1, threads, |input, output| {
            for (row, sum) in input.chunks_exact(width).zip(output) {
                *sum = row.iter().sum();
            }
        });
        output
    }

    #[test]
    fn each_row_is_worked_once_whatever_the_thread_count() {
        let input: Vec<u32> = (0..7 * 3).collect();
        let sums: Vec<u32> = input.chunks_exact(3).map(|row| row.iter().sum()).collect();
        for threads in 0..=9 {
            assert_eq!(
                row_sums(&input, 3, 7, threads),
                sums,
                "on {threads} threads"
            );
        }
    }

    #[test]
    fn output_rows_past_the_input_are_left_alone() {
        assert_eq!(row_sums(&[1, 2, 3, 4], 2, 4, 2), [3, 7, 0, 0]);
    }

    #[test]
    fn no_rows_means_no_work() {
        assert_eq!(row_sums(&[], 2, 0, 3), []);
        let mut output = [5u32; 2];
        in_row_bands(&[1u32, 2], 0, &mut output, 1, 2, |_, _| unreachable!());
        assert_eq!(output, [5, 5]);
    }
}
