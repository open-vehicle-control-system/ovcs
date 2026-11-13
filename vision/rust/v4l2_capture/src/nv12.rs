//! An output's RGB image as NV12 for a video encoder, in the encoder's
//! padded layout: BT.601 limited range (luma 16 to 235, chroma 16 to 240
//! about 128), as most decoders take a stream without colour description,
//! each chroma sample the mean of a 2x2 block of pixels.

use crate::bands;

/// Where an NV12 image lies in an encoder's buffer: `width` x `height`
/// luma samples in rows `stride` bytes apart, the interleaved blue and red
/// chroma plane after `luma_rows` rows, `size` bytes in all.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Nv12Layout {
    pub width: usize,
    pub height: usize,
    pub stride: usize,
    pub luma_rows: usize,
    pub size: usize,
}

impl Nv12Layout {
    fn chroma_offset(&self) -> usize {
        self.stride * self.luma_rows
    }
}

// The conversion is computed exactly in integers, its divisions by
// constants, so that it rounds as the real-valued one.

/// BT.601's weights of red, green and blue in luma, in thousandths.
const LUMA_WEIGHTS: [u32; 3] = [299, 587, 114];
const WEIGHT_SCALE: u32 = 1_000;
/// The span of luma and of chroma in limited range, over full range's 255.
const LUMA_SPAN: u32 = 219;
const CHROMA_SPAN: u32 = 224;
/// A colour difference's full-range divisor, 2 (1 - weight), in thousandths.
const BLUE_DIVISOR: u32 = 2 * (WEIGHT_SCALE - LUMA_WEIGHTS[2]);
const RED_DIVISOR: u32 = 2 * (WEIGHT_SCALE - LUMA_WEIGHTS[0]);

/// The weighted sum of red, green and blue, in thousandths.
#[inline(always)]
fn weighted([red, green, blue]: [u32; 3]) -> u32 {
    LUMA_WEIGHTS[0] * red + LUMA_WEIGHTS[1] * green + LUMA_WEIGHTS[2] * blue
}

/// The luma of a pixel, rounded.
#[inline(always)]
fn luma(pixel: [u32; 3]) -> u8 {
    const DIVISOR: u32 = 255 * WEIGHT_SCALE;
    (16 + (LUMA_SPAN * weighted(pixel) + DIVISOR / 2) / DIVISOR) as u8
}

/// The colour difference of `channel`'s sum over `pixels` pixels from
/// their luma sum, its full-range `divisor` in thousandths, rounded.
#[inline(always)]
fn difference(channel: u32, luma: u32, divisor: u32, pixels: u32) -> u8 {
    let divisor = divisor * 255 * pixels;
    let centred = CHROMA_SPAN as i32 * (WEIGHT_SCALE * channel) as i32
        - CHROMA_SPAN as i32 * luma as i32
        + (128 * divisor + divisor / 2) as i32;
    (centred as u32 / divisor) as u8
}

/// `rgb`, `layout.width` x `layout.height` 8-bit red, green and blue pixels,
/// into `nv12` laid out as `layout`, in bands of pairs of rows on up to
/// `threads` threads. The padding is left as it is. The width and height are
/// even.
pub fn convert(rgb: &[u8], layout: &Nv12Layout, threads: usize, nv12: &mut [u8]) {
    let (width, stride) = (layout.width, layout.stride);
    let (luma, chroma) = nv12[..layout.size].split_at_mut(layout.chroma_offset());
    let pairs = bands::split(layout.height / 2, threads);
    let (mut luma, mut chroma) = (&mut luma[..], &mut chroma[..]);
    let mut jobs = Vec::with_capacity(pairs.len());
    for band in &pairs {
        let (band_luma, rest) = std::mem::take(&mut luma).split_at_mut(band.len() * 2 * stride);
        luma = rest;
        let (band_chroma, rest) = std::mem::take(&mut chroma).split_at_mut(band.len() * stride);
        chroma = rest;
        let band_rgb = &rgb[band.start * 2 * width * 3..band.end * 2 * width * 3];
        jobs.push((band_rgb, band_luma, band_chroma));
    }
    let convert_band = move |(rgb, luma, chroma): (&[u8], &mut [u8], &mut [u8])| {
        convert_rows(rgb, width, stride, luma, chroma)
    };
    let last = jobs.pop().expect("a band");
    if jobs.is_empty() {
        return convert_band(last);
    }
    std::thread::scope(|scope| {
        let running: Vec<_> = (jobs.into_iter())
            .map(|job| scope.spawn(move || convert_band(job)))
            .collect();
        convert_band(last);
        for band in running {
            band.join()
                .unwrap_or_else(|panic| std::panic::resume_unwind(panic));
        }
    });
}

/// The pairs of rows of `rgb`, rows of `width` pixels, into the rows of
/// `luma` and `chroma` they make, `stride` bytes apart.
fn convert_rows(rgb: &[u8], width: usize, stride: usize, luma: &mut [u8], chroma: &mut [u8]) {
    for ((pair, luma_rows), chroma_row) in (rgb.chunks_exact(width * 6))
        .zip(luma.chunks_mut(stride * 2))
        .zip(chroma.chunks_mut(stride))
    {
        convert_pair(pair, width, stride, luma_rows, chroma_row);
    }
}

/// A pair of rows of `width` pixels, `rgb`, into the two rows of `luma`
/// they make, `stride` bytes apart, and the row of `chroma`.
pub(crate) fn convert_pair(
    rgb: &[u8],
    width: usize,
    stride: usize,
    luma: &mut [u8],
    chroma: &mut [u8],
) {
    let (top, bottom) = rgb.split_at(width * 3);
    let (luma_top, luma_bottom) = luma.split_at_mut(stride);
    luma_row(top, &mut luma_top[..width]);
    luma_row(bottom, &mut luma_bottom[..width]);
    let blocks = top.chunks_exact(6).zip(bottom.chunks_exact(6));
    for ((top, bottom), samples) in blocks.zip(chroma[..width].chunks_exact_mut(2)) {
        let sums = [0, 1, 2].map(|channel| {
            u32::from(top[channel])
                + u32::from(top[channel + 3])
                + u32::from(bottom[channel])
                + u32::from(bottom[channel + 3])
        });
        let luma = weighted(sums);
        samples[0] = difference(sums[2], luma, BLUE_DIVISOR, 4);
        samples[1] = difference(sums[0], luma, RED_DIVISOR, 4);
    }
}

fn luma_row(rgb: &[u8], samples: &mut [u8]) {
    for (pixel, sample) in rgb.chunks_exact(3).zip(samples) {
        *sample = luma([pixel[0], pixel[1], pixel[2]].map(u32::from));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // BT.601 limited range in floating point, each value one division of
    // whole numbers, so that a value halfway between two rounds up.
    fn reference_ycbcr([red, green, blue]: [f64; 3]) -> [u8; 3] {
        let luma_thousandths = 299.0 * red + 587.0 * green + 114.0 * blue;
        let difference = |channel: f64, divisor: f64| {
            128.0 + 224.0 * (1_000.0 * channel - luma_thousandths) / (divisor * 255.0)
        };
        [
            16.0 + 219.0 * luma_thousandths / 255_000.0,
            difference(blue, 1_772.0),
            difference(red, 1_402.0),
        ]
        .map(|value| value.round() as u8)
    }

    // The NV12 of `rgb`, each chroma sample from the mean of its block, one pixel at a time.
    fn reference(rgb: &[u8], layout: &Nv12Layout) -> Vec<u8> {
        let mut nv12 = vec![0; layout.size];
        let pixel = |x: usize, y: usize| -> [f64; 3] {
            let at = (y * layout.width + x) * 3;
            [0, 1, 2].map(|channel| f64::from(rgb[at + channel]))
        };
        for y in 0..layout.height {
            for x in 0..layout.width {
                nv12[y * layout.stride + x] = reference_ycbcr(pixel(x, y))[0];
            }
        }
        for y in 0..layout.height / 2 {
            for x in 0..layout.width / 2 {
                let mut mean = [0.0; 3];
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let pixel = pixel(2 * x + dx, 2 * y + dy);
                    (0..3).for_each(|channel| mean[channel] += pixel[channel] / 4.0);
                }
                let [_, blue, red] = reference_ycbcr(mean);
                let at = layout.chroma_offset() + y * layout.stride + 2 * x;
                nv12[at] = blue;
                nv12[at + 1] = red;
            }
        }
        nv12
    }

    fn layout(width: usize, height: usize, stride: usize, luma_rows: usize) -> Nv12Layout {
        Nv12Layout {
            width,
            height,
            stride,
            luma_rows,
            size: stride * luma_rows * 3 / 2,
        }
    }

    fn noise(length: usize) -> Vec<u8> {
        let mut state = 0x2545_f491u32;
        (0..length)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                state as u8
            })
            .collect()
    }

    fn converted(rgb: &[u8], layout: &Nv12Layout, threads: usize) -> Vec<u8> {
        let mut nv12 = vec![0; layout.size];
        convert(rgb, layout, threads, &mut nv12);
        nv12
    }

    #[test]
    fn a_flat_colour_converts_exactly_to_bt601_limited_range() {
        let layout = layout(4, 2, 4, 2);
        let mut colours = vec![
            [0, 0, 0],
            [255, 255, 255],
            [255, 0, 0],
            [0, 255, 0],
            [0, 0, 255],
        ];
        let steps = (0..=255).step_by(3);
        for red in steps.clone() {
            for green in steps.clone() {
                for blue in steps.clone() {
                    colours.push([red, green, blue]);
                }
            }
        }
        for colour in colours {
            let rgb: Vec<u8> = colour.repeat(8);
            let nv12 = converted(&rgb, &layout, 1);
            let [luma, blue, red] = reference_ycbcr(colour.map(f64::from));
            assert_eq!(nv12[..8], [luma; 8], "{colour:?}");
            assert_eq!(nv12[8..], [blue, red, blue, red], "{colour:?}");
        }
        assert_eq!(reference_ycbcr([0.0; 3]), [16, 128, 128]);
        assert_eq!(reference_ycbcr([255.0; 3]), [235, 128, 128]);
    }

    #[test]
    fn an_image_converts_within_one_of_the_reference_into_the_padded_layout() {
        for (width, height, stride, luma_rows) in
            [(24, 46, 32, 64), (36, 6, 36, 6), (8, 2, 128, 32)]
        {
            let layout = layout(width, height, stride, luma_rows);
            let rgb = noise(width * height * 3);
            let expected = reference(&rgb, &layout);
            for threads in 1..=4 {
                let nv12 = converted(&rgb, &layout, threads);
                for (at, (got, want)) in nv12.iter().zip(&expected).enumerate() {
                    assert!(
                        got.abs_diff(*want) <= 1,
                        "{width}x{height} on {threads} threads, byte {at}: {got} for {want}"
                    );
                }
                let padding = |nv12: &[u8]| -> Vec<u8> {
                    (nv12.chunks(stride).flat_map(|row| row[width..].to_vec())).collect()
                };
                assert!(padding(&nv12).iter().all(|&byte| byte == 0));
                assert_eq!(padding(&expected).len(), padding(&nv12).len());
            }
        }
    }

    #[test]
    #[ignore = "a benchmark: run with `-- --ignored --nocapture` to print the host's times"]
    fn host_time_of_a_full_frame_converted_to_nv12() {
        let layout = layout(2028, 1520, 2048, 1536);
        let rgb = noise(2028 * 1520 * 3);
        let mut nv12 = vec![0; layout.size];
        for threads in [1, 3] {
            convert(&rgb, &layout, threads, &mut nv12);
            let runs = 30;
            let started = std::time::Instant::now();
            for _ in 0..runs {
                convert(&rgb, &layout, threads, &mut nv12);
            }
            println!(
                "NV12 of 2028x1520 on {threads} threads: {:?}",
                started.elapsed() / runs
            );
        }
    }
}
