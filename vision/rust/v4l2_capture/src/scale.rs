//! An output scaled from another one, after the processors: each pixel the
//! average of the block of the source's pixels it covers. The CPU processor
//! makes the 2x2 average of its own output as it converts (`bands::Images`).

use crate::bands;

/// `source`, rows of `source_width` 8-bit red, green and blue pixels, into
/// `image`, each pixel the rounded mean of a `block_width` x `block_height`
/// block of `source`, the blocks tiling it from its top-left corner; rows
/// split in bands over up to `threads` threads. The source's width and
/// height are whole multiples of the block's.
pub fn average_blocks(
    source: &[u8],
    source_width: usize,
    (block_width, block_height): (usize, usize),
    threads: usize,
    image: &mut Vec<u8>,
) {
    let source_height = source.len() / (source_width * 3).max(1);
    let (width, height) = (source_width / block_width, source_height / block_height);
    image.resize(width * height * 3, 0);
    let source_rows = source_width * 3 * block_height;
    bands::in_row_bands(
        source,
        source_rows,
        image,
        width * 3,
        threads,
        |rows, out| average_rows(rows, source_width, (block_width, block_height), out),
    );
}

/// The rows of blocks of `rows`, rows of `source_width` pixels, averaged
/// into `out`.
pub(crate) fn average_rows(
    rows: &[u8],
    source_width: usize,
    (block_width, block_height): (usize, usize),
    out: &mut [u8],
) {
    let row_bytes = source_width * 3;
    // The common block, without the general path's row of sums.
    if (block_width, block_height) == (2, 2) {
        for (pair, out_row) in rows
            .chunks_exact(row_bytes * 2)
            .zip(out.chunks_exact_mut(row_bytes / 2))
        {
            let (top, bottom) = pair.split_at(row_bytes);
            for ((top, bottom), pixel) in top
                .chunks_exact(6)
                .zip(bottom.chunks_exact(6))
                .zip(out_row.chunks_exact_mut(3))
            {
                for channel in 0..3 {
                    let sum = u16::from(top[channel])
                        + u16::from(top[channel + 3])
                        + u16::from(bottom[channel])
                        + u16::from(bottom[channel + 3]);
                    pixel[channel] = ((sum + 2) >> 2) as u8;
                }
            }
        }
        return;
    }
    let count = block_width * block_height;
    // The rounded mean of every sum a block can have.
    let means: Vec<u8> = (0..=255 * count)
        .map(|sum| ((sum + count / 2) / count) as u8)
        .collect();
    let mut column_sums = vec![0u32; row_bytes];
    for (block_row, out_row) in rows
        .chunks_exact(row_bytes * block_height)
        .zip(out.chunks_exact_mut(row_bytes / block_width))
    {
        column_sums.fill(0);
        for row in block_row.chunks_exact(row_bytes) {
            for (sum, &value) in column_sums.iter_mut().zip(row) {
                *sum += u32::from(value);
            }
        }
        for (block, pixel) in column_sums
            .chunks_exact(block_width * 3)
            .zip(out_row.chunks_exact_mut(3))
        {
            let mut sum = [0u32; 3];
            for column in block.chunks_exact(3) {
                sum[0] += column[0];
                sum[1] += column[1];
                sum[2] += column[2];
            }
            for (value, sum) in pixel.iter_mut().zip(sum) {
                *value = means[sum as usize];
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Noise, so that no two blocks are alike.
    fn noise(length: usize) -> Vec<u8> {
        let mut state = 0x9e37_79b9u32;
        (0..length)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                state as u8
            })
            .collect()
    }

    // Each pixel's channels averaged over its block, one pixel at a time.
    fn reference(source: &[u8], width: usize, height: usize, (bw, bh): (usize, usize)) -> Vec<u8> {
        let mut image = Vec::new();
        for y in 0..height / bh {
            for x in 0..width / bw {
                for channel in 0..3 {
                    let mut sum = 0u32;
                    for dy in 0..bh {
                        for dx in 0..bw {
                            let pixel = (y * bh + dy) * width + x * bw + dx;
                            sum += u32::from(source[pixel * 3 + channel]);
                        }
                    }
                    let count = (bw * bh) as u32;
                    image.push(((sum + count / 2) / count) as u8);
                }
            }
        }
        image
    }

    #[test]
    fn each_pixel_is_the_rounded_mean_of_its_block() {
        // Two pixels of 2x2 blocks: red 0, 1, 2, 2 -> 1.25 -> 1; 10, 11, 10, 11 -> 10.5 -> 11.
        let source = [
            0, 10, 255, 1, 11, 255, 7, 7, 7, 9, 9, 9, //
            2, 10, 254, 2, 11, 254, 8, 8, 8, 8, 8, 8,
        ];
        let mut image = Vec::new();
        average_blocks(&source, 4, (2, 2), 1, &mut image);
        assert_eq!(image, [1, 11, 255, 8, 8, 8]);
    }

    #[test]
    fn the_image_is_the_reference_average_for_any_block_and_threads() {
        for (width, height) in [(24, 46), (36, 6), (12, 12), (40, 30)] {
            let source = noise(width * height * 3);
            for block in [(1, 1), (2, 2), (2, 1), (3, 2), (4, 2), (2, 3)] {
                if width % block.0 != 0 || height % block.1 != 0 {
                    continue;
                }
                let expected = reference(&source, width, height, block);
                let mut image = vec![0xaa; 5];
                for threads in [1, 2, 3, 4, 8] {
                    average_blocks(&source, width, block, threads, &mut image);
                    assert!(
                        image == expected,
                        "{width}x{height} by {block:?} on {threads} threads"
                    );
                }
            }
        }
    }

    #[test]
    #[ignore = "a benchmark: run with `-- --ignored --nocapture` to print the host's times"]
    fn host_time_of_a_2x2_average_of_a_full_frame() {
        let (width, height) = (2028, 1520);
        let source = noise(width * height * 3);
        let mut image = Vec::new();
        for threads in [1, 3] {
            average_blocks(&source, width, (2, 2), threads, &mut image);
            let runs = 50;
            let started = std::time::Instant::now();
            for _ in 0..runs {
                average_blocks(&source, width, (2, 2), threads, &mut image);
            }
            let per_frame = started.elapsed() / runs;
            println!("2x2 average of {width}x{height} on {threads} threads: {per_frame:?}");
        }
    }
}
