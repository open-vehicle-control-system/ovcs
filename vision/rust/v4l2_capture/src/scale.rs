//! An output scaled from another one, after the processors: each pixel the
//! average of the block of the source's pixels it covers. The CPU processor
//! makes the 2x2 average of its own output as it converts (`bands::Images`).

use crate::bands;

/// Averages blocks of an image's pixels, through buffers kept from one image to the next.
#[derive(Default)]
pub struct Averager {
    /// The rounded mean of every sum a block of `block_pixels` pixels can have.
    means: Vec<u8>,
    block_pixels: usize,
    /// Each band's sums down the columns of a row of blocks.
    column_sums: Vec<Vec<u32>>,
}

impl Averager {
    /// `source`, rows of `source_width` 8-bit red, green and blue pixels, into
    /// `image`, each pixel the rounded mean of a `block_width` x `block_height`
    /// block of `source`, the blocks tiling it from its top-left corner; rows
    /// split in bands over up to `threads` threads. The source's width and
    /// height are whole multiples of the block's.
    pub fn average_blocks(
        &mut self,
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
        // The common block, without the general path's sums.
        if (block_width, block_height) == (2, 2) {
            let mut no_scratch = Vec::new();
            return bands::in_row_bands(
                (source, source_rows),
                (image, width * 3),
                threads,
                &mut no_scratch,
                |rows, out, ()| average_pairs(rows, source_width, out),
            );
        }
        let block_pixels = block_width * block_height;
        if self.block_pixels != block_pixels {
            self.block_pixels = block_pixels;
            self.means.clear();
            self.means.extend(
                (0..=255 * block_pixels).map(|sum| ((sum + block_pixels / 2) / block_pixels) as u8),
            );
        }
        let means = &self.means[..];
        bands::in_row_bands(
            (source, source_rows),
            (image, width * 3),
            threads,
            &mut self.column_sums,
            |rows, out, column_sums| {
                let block = (block_width, block_height);
                average_rows(rows, source_width, block, means, column_sums, out)
            },
        );
    }
}

/// The rows of 2x2 blocks of `rows`, rows of `source_width` pixels, averaged into `out`.
pub(crate) fn average_pairs(rows: &[u8], source_width: usize, out: &mut [u8]) {
    let row_bytes = source_width * 3;
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
}

/// The rows of blocks of `rows`, rows of `source_width` pixels, averaged into `out`:
/// each block's sum, added up through `column_sums`, to its mean in `means`.
fn average_rows(
    rows: &[u8],
    source_width: usize,
    (block_width, block_height): (usize, usize),
    means: &[u8],
    column_sums: &mut Vec<u32>,
    out: &mut [u8],
) {
    let row_bytes = source_width * 3;
    column_sums.resize(row_bytes, 0);
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
        Averager::default().average_blocks(&source, 4, (2, 2), 1, &mut image);
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
                    Averager::default().average_blocks(&source, width, block, threads, &mut image);
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
            Averager::default().average_blocks(&source, width, (2, 2), threads, &mut image);
            let runs = 50;
            let started = std::time::Instant::now();
            for _ in 0..runs {
                Averager::default().average_blocks(&source, width, (2, 2), threads, &mut image);
            }
            let per_frame = started.elapsed() / runs;
            println!("2x2 average of {width}x{height} on {threads} threads: {per_frame:?}");
        }
    }
}
