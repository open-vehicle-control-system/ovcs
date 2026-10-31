//! `VisionCore.Stereo.Pipeline`'s stages on the CPU, with the results of
//! their Nx implementations. `Matcher` is `NxStereo.sgm/3`'s semi-global
//! matching: integer disparities, unmatched pixels and the subpixel values,
//! which use the same `f32` operations. `segment::Segment` runs a run of
//! stages, the matching among them, on each pair.

mod census;
mod check;
mod depth;
mod filters;
mod measures;
pub mod parallel;
mod paths;
pub mod protocol;
mod rectify;
#[cfg(test)]
mod reference;
pub mod segment;
mod select;
pub mod tensor;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use parallel::{on_threads, Backoff, Chunks, RowQueue, Shared};
use paths::{Sweep, SweepBuffers};

/// The matching settings, as `NxStereo.sgm/3` takes them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Params {
    pub disparities: usize,
    pub paths: u8,
    pub p1: u8,
    pub p2: u8,
    pub uniqueness: f32,
}

/// The highest Hamming distance between two Census features.
pub const CENSUS_BITS: u8 = 48;

impl Params {
    /// Why `NxStereo.sgm/3` would refuse these settings for a `width` x
    /// `height` pair, if it would.
    pub fn check(&self, width: usize, height: usize) -> Result<(), String> {
        if !(width > 8 && height > 6 && width <= 4096) {
            return Err(format!("expected an image wider than 8, higher than 6 and at most 4096 wide, got {width}x{height}"));
        }
        if self.disparities != 64 && self.disparities != 128 {
            return Err(format!(
                "disparities must be 64 or 128, got {}",
                self.disparities
            ));
        }
        if self.paths != 3 && self.paths != 8 {
            return Err(format!("paths must be 3 or 8, got {}", self.paths));
        }
        if !(self.p1 < self.p2 && u16::from(self.p2) + u16::from(CENSUS_BITS) <= 127) {
            return Err(format!(
                "expected 0 <= p1 < p2 <= {}, got {} and {}",
                127 - CENSUS_BITS,
                self.p1,
                self.p2
            ));
        }
        if self.uniqueness.is_nan() || self.uniqueness < 1.0 {
            return Err(format!(
                "uniqueness must be at least 1.0, got {}",
                self.uniqueness
            ));
        }
        Ok(())
    }
}

/// Matches pairs, keeping its buffers from one pair to the next.
pub struct Matcher {
    threads: usize,
    costs: Vec<u8>,
    horizontal: Vec<u8>,
    totals: Vec<u16>,
    selected: Vec<f32>,
    keys: Vec<u32>,
    checked: Vec<f32>,
    states: Vec<u8>,
    minimums: Vec<u8>,
    sweep: SweepBuffers,
}

impl Matcher {
    pub fn new(threads: usize) -> Matcher {
        Matcher {
            threads: threads.max(1),
            costs: Vec::new(),
            horizontal: Vec::new(),
            totals: Vec::new(),
            selected: Vec::new(),
            keys: Vec::new(),
            checked: Vec::new(),
            states: Vec::new(),
            minimums: Vec::new(),
            sweep: SweepBuffers::default(),
        }
    }

    /// The disparity of each pixel of `left`, `-1.0` where unmatched, for
    /// settings that pass `Params::check`.
    pub fn disparity(
        &mut self,
        left: &[u8],
        right: &[u8],
        width: usize,
        height: usize,
        params: &Params,
    ) -> Vec<f32> {
        assert!(
            params.check(width, height).is_ok()
                && left.len() == width * height
                && right.len() == width * height
        );
        match params.disparities {
            64 => self.run::<64>(left, right, width, height, params),
            _ => self.run::<128>(left, right, width, height, params),
        }
    }

    fn run<const D: usize>(
        &mut self,
        left: &[u8],
        right: &[u8],
        width: usize,
        height: usize,
        params: &Params,
    ) -> Vec<f32> {
        self.selected.resize(width * height, 0.0);
        self.keys.resize(width * height, 0);
        self.checked.resize(width * height, 0.0);
        if params.paths == 3 {
            self.three_paths::<D>(left, right, width, height, params);
        } else {
            self.costs_and_rows::<D>(left, right, width, height, params);
            self.eight_paths::<D>(width, height, params);
        }
        self.check(width, height)
    }

    /// Each row's matching costs and the sum of its two horizontal paths.
    fn costs_and_rows<const D: usize>(
        &mut self,
        left: &[u8],
        right: &[u8],
        width: usize,
        height: usize,
        params: &Params,
    ) {
        let volume = width * height * D;
        self.costs.resize(volume, 0);
        self.horizontal.resize(volume, 0);
        let rows = RowQueue::new(height);
        let costs = Shared::new(&mut self.costs);
        let horizontal = Shared::new(&mut self.horizontal);
        let work = |_thread| {
            let mut scratch = RowScratch::default();
            while let Some(range) = rows.take() {
                for y in range {
                    let row = y * width * D..(y + 1) * width * D;
                    // SAFETY: the queue hands each row to one thread.
                    let (costs, horizontal) =
                        unsafe { (costs.slice_mut(row.clone()), horizontal.slice_mut(row)) };
                    scratch.costs_and_paths::<D>(
                        left, right, width, height, y, params, costs, horizontal,
                    );
                }
            }
        };
        on_threads(self.threads.min(height), &work);
    }

    /// The horizontal paths, the vertical one and selection, in one pass
    /// down the image. Threads compute rows' costs and horizontal paths
    /// into a ring of rows that stays in the cache, and follow the vertical
    /// path down column chunks over the rows ready, freeing them.
    fn three_paths<const D: usize>(
        &mut self,
        left: &[u8],
        right: &[u8],
        width: usize,
        height: usize,
        params: &Params,
    ) {
        let ring_rows = (RING_BYTES / (2 * width * D)).clamp(2, height);
        let row_len = width * D;
        let stride = D + 2;
        self.costs.resize(ring_rows * row_len, 0);
        self.horizontal.resize(ring_rows * row_len, 0);
        self.states.resize(2 * width * stride, 0);
        for state in self.states.chunks_exact_mut(stride) {
            paths::reset_state::<D>(state);
        }
        self.minimums.clear();
        self.minimums.resize(2 * width, 0);
        let (costs, horizontal) = (
            Shared::new(&mut self.costs),
            Shared::new(&mut self.horizontal),
        );
        let (states, minimums) = (
            Shared::new(&mut self.states),
            Shared::new(&mut self.minimums),
        );
        let (selected, keys) = (Shared::new(&mut self.selected), Shared::new(&mut self.keys));
        // Row y is in its ring slot once the slot holds y + 1.
        let produced: Vec<AtomicUsize> = (0..ring_rows).map(|_| AtomicUsize::new(0)).collect();
        let next_row = AtomicUsize::new(0);
        let chunks = Chunks::new(width, self.threads);
        let threads = self.threads.min(height);
        let ready =
            |y: usize| y < height && produced[y % ring_rows].load(Ordering::Acquire) == y + 1;

        let vertical_row = |chunk: usize, y: usize, sums: &mut [u16; D]| {
            let ring_row = (y % ring_rows) * row_len;
            let (current, previous) = (y % 2, 1 - y % 2);
            for x in chunks.columns(chunk) {
                let at = ring_row + x * D;
                // SAFETY: the ring row is not written again before every chunk
                // has done it, and the chunk's columns are the holder's alone.
                unsafe {
                    let (costs, horizontal) =
                        (costs.slice(at..at + D), horizontal.slice(at..at + D));
                    let source = previous * width + x;
                    let target = current * width + x;
                    let next = states.slice_mut(target * stride..(target + 1) * stride);
                    minimums.slice_mut(target..target + 1)[0] = paths::step::<D>(
                        states.slice(source * stride..(source + 1) * stride),
                        minimums.slice(source..source + 1)[0],
                        costs,
                        next,
                        params.p1,
                        params.p2,
                    );
                    for ((sum, &horizontal), &vertical) in
                        sums.iter_mut().zip(horizontal).zip(&next[1..D + 1])
                    {
                        *sum = u16::from(horizontal) + u16::from(vertical);
                    }
                    select_into::<D>(sums, y * width + x, x, params.uniqueness, &selected, &keys);
                }
            }
        };

        let work = |thread: usize| {
            let mut scratch = RowScratch::default();
            let mut sums = [0u16; D];
            let mut backoff = Backoff::default();
            loop {
                let mut progressed = false;
                for offset in 0..chunks.count() {
                    let chunk = (thread * chunks.count() / threads + offset) % chunks.count();
                    if !ready(chunks.progress(chunk)) || !chunks.try_claim(chunk) {
                        continue;
                    }
                    let (first, mut y) = (chunks.progress(chunk), chunks.progress(chunk));
                    while ready(y) && y - first < ROWS_PER_CLAIM {
                        vertical_row(chunk, y, &mut sums);
                        y += 1;
                    }
                    chunks.set_progress(chunk, y);
                    chunks.release(chunk);
                    progressed |= y > first;
                }
                // A row may go into the ring once every chunk is done with the row it replaces.
                let row = next_row.load(Ordering::Acquire);
                if row < height
                    && row < chunks.min_progress() + ring_rows
                    && next_row
                        .compare_exchange(row, row + 1, Ordering::AcqRel, Ordering::Relaxed)
                        .is_ok()
                {
                    let slot = (row % ring_rows) * row_len..(row % ring_rows + 1) * row_len;
                    // SAFETY: the slot's previous row is done by every chunk, and
                    // this thread alone took this row.
                    let (costs, horizontal) =
                        unsafe { (costs.slice_mut(slot.clone()), horizontal.slice_mut(slot)) };
                    scratch.costs_and_paths::<D>(
                        left, right, width, height, row, params, costs, horizontal,
                    );
                    produced[row % ring_rows].store(row + 1, Ordering::Release);
                    progressed = true;
                }
                if progressed {
                    backoff.reset();
                } else if chunks.min_progress() == height {
                    break;
                } else {
                    backoff.wait();
                }
            }
        };
        on_threads(threads, &work);
    }

    /// The three downward paths, then the three upward ones and selection.
    fn eight_paths<const D: usize>(&mut self, width: usize, height: usize, params: &Params) {
        self.totals.resize(width * height * D, 0);
        let (horizontal, totals) = (&self.horizontal, Shared::new(&mut self.totals));
        let mut sweep = Sweep {
            down: true,
            offsets: [0, 1, -1],
            width,
            height,
            costs: &self.costs,
            p1: params.p1,
            p2: params.p2,
            threads: self.threads,
        };
        sweep.run::<D, _>(&mut self.sweep, |y, x, [a, b, c]| {
            let at = (y * width + x) * D;
            // SAFETY: each pixel is visited once.
            let totals: &mut [u16; D] = unsafe { totals.slice_mut(at..at + D) }.try_into().unwrap();
            let horizontal: &[u8; D] = horizontal[at..at + D].try_into().unwrap();
            for d in 0..D {
                totals[d] =
                    u16::from(horizontal[d]) + u16::from(a[d]) + u16::from(b[d]) + u16::from(c[d]);
            }
        });
        sweep.down = false;
        let (selected, keys) = (Shared::new(&mut self.selected), Shared::new(&mut self.keys));
        sweep.run::<D, _>(&mut self.sweep, |y, x, [a, b, c]| {
            let at = (y * width + x) * D;
            // SAFETY: each pixel is visited once, after the downward sweep.
            let totals: &[u16; D] = unsafe { totals.slice(at..at + D) }.try_into().unwrap();
            let sums: [u16; D] = std::array::from_fn(|d| {
                totals[d] + u16::from(a[d]) + u16::from(b[d]) + u16::from(c[d])
            });
            // SAFETY: each pixel is visited once.
            unsafe {
                select_into::<D>(&sums, y * width + x, x, params.uniqueness, &selected, &keys)
            };
        });
    }

    /// The left-right check of every row, then the median filter, each
    /// median row once the three checked rows it reads are done.
    fn check(&mut self, width: usize, height: usize) -> Vec<f32> {
        let mut out = vec![0.0; width * height];
        let (checked_rows, median_rows) = (RowQueue::new(height), RowQueue::new(height));
        let done: Vec<AtomicBool> = (0..height).map(|_| AtomicBool::new(false)).collect();
        let (selected, keys) = (&self.selected, &self.keys);
        let (checked, filtered) = (Shared::new(&mut self.checked), Shared::new(&mut out));
        let row = |y: usize| y * width..(y + 1) * width;
        let work = |_thread| {
            let mut right = Vec::new();
            while let Some(range) = checked_rows.take() {
                for y in range {
                    // SAFETY: the queue hands each row to one thread.
                    let out = unsafe { checked.slice_mut(row(y)) };
                    check::consistency_row(&selected[row(y)], &keys[row(y)], &mut right, out);
                    done[y].store(true, Ordering::Release);
                }
            }
            let (mut keys, mut backoff) = (Vec::new(), Backoff::default());
            while let Some(range) = median_rows.take() {
                for y in range {
                    let neighbours = [y.saturating_sub(1), y, (y + 1).min(height - 1)];
                    while !neighbours.iter().all(|&y| done[y].load(Ordering::Acquire)) {
                        backoff.wait();
                    }
                    backoff.reset();
                    // SAFETY: checked rows are not written once done, and the
                    // queue hands each median row to one thread.
                    let (rows, out) = unsafe {
                        (
                            neighbours.map(|y| checked.slice(row(y))),
                            filtered.slice_mut(row(y)),
                        )
                    };
                    check::median_row(rows, &mut keys, out);
                }
            }
        };
        on_threads(self.threads.min(height), &work);
        out
    }
}

/// The ring of rows' costs and horizontal sums, in about the shared cache
/// of a Raspberry Pi 5.
const RING_BYTES: usize = 1 << 20;
/// Rows a thread follows a chunk down before it looks for other work.
const ROWS_PER_CLAIM: usize = 8;

/// What a thread computes a row's costs and horizontal paths with.
#[derive(Default)]
struct RowScratch {
    padded: Vec<u8>,
    left: Vec<u8>,
    right: Vec<u8>,
    reversed: Vec<u8>,
    backward: Vec<u8>,
}

impl RowScratch {
    #[allow(clippy::too_many_arguments)]
    fn costs_and_paths<const D: usize>(
        &mut self,
        left: &[u8],
        right: &[u8],
        width: usize,
        height: usize,
        y: usize,
        params: &Params,
        costs: &mut [u8],
        horizontal: &mut [u8],
    ) {
        self.left.resize(census::PLANES * width, 0);
        self.right.resize(census::PLANES * width, 0);
        self.backward.resize(width * D, 0);
        census::census_row(left, width, height, y, &mut self.padded, &mut self.left);
        census::census_row(right, width, height, y, &mut self.padded, &mut self.right);
        census::reverse_right(&self.right, width, D, &mut self.reversed);
        census::costs_row::<D>(&self.left, &self.reversed, width, costs);
        paths::horizontal_row::<D>(costs, horizontal, &mut self.backward, params.p1, params.p2);
    }
}

/// # Safety
/// No other thread may access pixel `index` meanwhile.
#[inline(always)]
unsafe fn select_into<const D: usize>(
    sums: &[u16; D],
    index: usize,
    x: usize,
    uniqueness: f32,
    selected: &Shared<f32>,
    keys: &Shared<u32>,
) {
    let (disparity, key) = select::select::<D>(sums, x, uniqueness);
    selected.slice_mut(index..index + 1)[0] = disparity;
    keys.slice_mut(index..index + 1)[0] = key;
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A xorshift generator, for reproducible images.
    pub struct Random(u64);

    impl Random {
        pub fn new(seed: u64) -> Random {
            Random(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
        }

        pub fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }

        pub fn byte(&mut self) -> u8 {
            (self.next() >> 24) as u8
        }
    }

    pub fn noise(width: usize, height: usize, seed: u64) -> Vec<u8> {
        let mut random = Random::new(seed);
        (0..width * height).map(|_| random.byte()).collect()
    }

    /// A smooth texture seen through a slanted plane, so disparities vary
    /// across the image and subpixel refinement has work, with a flat patch
    /// that leaves ties and unmatched pixels.
    pub fn scene(width: usize, height: usize, seed: u64) -> (Vec<u8>, Vec<u8>) {
        let mut random = Random::new(seed);
        let texture_width = width + 160;
        let coarse: Vec<f32> = (0..texture_width * height)
            .map(|_| f32::from(random.byte()))
            .collect();
        let texture = |y: usize, x: f32| {
            let x0 = x.floor().clamp(0.0, texture_width as f32 - 2.0) as usize;
            let t = x - x0 as f32;
            coarse[y * texture_width + x0] * (1.0 - t) + coarse[y * texture_width + x0 + 1] * t
        };
        let mut left = vec![0u8; width * height];
        let mut right = vec![0u8; width * height];
        for y in 0..height {
            for x in 0..width {
                let disparity =
                    4.0 + 30.0 * x as f32 / width as f32 + 6.0 * y as f32 / height as f32;
                let flat =
                    x > width / 3 && x < width / 3 + 10 && y > height / 2 && y < height / 2 + 8;
                left[y * width + x] = if flat {
                    90
                } else {
                    texture(y, x as f32 + 100.0) as u8
                };
                right[y * width + x] = if flat {
                    90
                } else {
                    texture(y, x as f32 + 100.0 + disparity) as u8
                };
            }
        }
        (left, right)
    }

    pub fn params(disparities: usize, paths: u8) -> Params {
        Params {
            disparities,
            paths,
            p1: 8,
            p2: 64,
            uniqueness: 1.0526316,
        }
    }

    fn assert_same(got: &[f32], want: &[f32], label: &str) {
        assert_eq!(got.len(), want.len(), "{label}: length");
        let differing: Vec<usize> = (0..want.len())
            .filter(|&i| got[i].to_bits() != want[i].to_bits())
            .collect();
        assert!(
            differing.is_empty(),
            "{label}: {} pixels differ, first at {}: {} instead of {}",
            differing.len(),
            differing[0],
            got[differing[0]],
            want[differing[0]]
        );
    }

    #[test]
    fn matches_the_reference_on_noise_and_scenes() {
        for (width, height) in [(64, 48), (97, 31)] {
            for disparities in [64, 128] {
                for paths in [3, 8] {
                    let params = params(disparities, paths);
                    let (left, right) = scene(width, height, 7);
                    let want = reference::sgm(&left, &right, width, height, &params);
                    for threads in [1, 3, 4] {
                        let got =
                            Matcher::new(threads).disparity(&left, &right, width, height, &params);
                        assert_same(
                            &got,
                            &want,
                            &format!("scene {width}x{height} {params:?} {threads} threads"),
                        );
                    }
                    let (left, right) = (noise(width, height, 1), noise(width, height, 2));
                    let want = reference::sgm(&left, &right, width, height, &params);
                    let got = Matcher::new(4).disparity(&left, &right, width, height, &params);
                    assert_same(&got, &want, &format!("noise {width}x{height} {params:?}"));
                }
            }
        }
    }

    #[test]
    fn matches_the_reference_for_other_penalties_and_uniqueness() {
        let (width, height) = (80, 40);
        let (left, right) = scene(width, height, 3);
        for (p1, p2, uniqueness) in [
            (0, 1, 1.0),
            (4, 40, 1.2),
            (78, 79, 2.5),
            (10, 79, 1.0526316),
        ] {
            for paths in [3, 8] {
                let params = Params {
                    disparities: 64,
                    paths,
                    p1,
                    p2,
                    uniqueness,
                };
                let want = reference::sgm(&left, &right, width, height, &params);
                let got = Matcher::new(4).disparity(&left, &right, width, height, &params);
                assert_same(&got, &want, &format!("{params:?}"));
            }
        }
    }

    #[test]
    fn matches_the_reference_when_the_ring_of_rows_wraps() {
        let (width, height) = (512, 40);
        assert!(RING_BYTES / (2 * width * 64) < height);
        let (left, right) = scene(width, height, 13);
        for disparities in [64, 128] {
            let params = params(disparities, 3);
            let want = reference::sgm(&left, &right, width, height, &params);
            for threads in [1, 3, 4, 8] {
                let got = Matcher::new(threads).disparity(&left, &right, width, height, &params);
                assert_same(
                    &got,
                    &want,
                    &format!("{disparities} disparities, {threads} threads"),
                );
            }
        }
    }

    #[test]
    fn keeps_matching_after_a_pair_of_another_size() {
        let mut matcher = Matcher::new(4);
        let params = params(64, 8);
        for (width, height) in [(96, 64), (64, 48), (96, 64)] {
            let (left, right) = scene(width, height, 5);
            let want = reference::sgm(&left, &right, width, height, &params);
            assert_same(
                &matcher.disparity(&left, &right, width, height, &params),
                &want,
                "resized",
            );
        }
    }

    #[test]
    fn a_shifted_scene_measures_its_disparity() {
        let (width, height) = (96, 64);
        let (left, right) = scene(width, height, 11);
        let disparity = Matcher::new(2).disparity(&left, &right, width, height, &params(64, 8));
        let (x, y) = (60, 20);
        // The right pixel u showing left pixel x satisfies u + disparity(u) = x.
        let u = (x as f32 - 4.0 - 6.0 * y as f32 / height as f32) / (1.0 + 30.0 / width as f32);
        let expected = x as f32 - u;
        assert!(
            (disparity[y * width + x] - expected).abs() < 1.0,
            "{} instead of {expected}",
            disparity[y * width + x]
        );
    }

    #[test]
    fn check_refuses_what_nx_stereo_refuses() {
        let good = params(64, 3);
        assert_eq!(good.check(64, 48), Ok(()));
        assert!(good.check(8, 48).is_err());
        assert!(good.check(64, 6).is_err());
        assert!(good.check(4097, 48).is_err());
        assert!(Params {
            disparities: 96,
            ..good
        }
        .check(64, 48)
        .is_err());
        assert!(Params { paths: 4, ..good }.check(64, 48).is_err());
        assert!(Params {
            p1: 64,
            p2: 64,
            ..good
        }
        .check(64, 48)
        .is_err());
        assert!(Params {
            p1: 8,
            p2: 80,
            ..good
        }
        .check(64, 48)
        .is_err());
        assert!(Params {
            uniqueness: 0.9,
            ..good
        }
        .check(64, 48)
        .is_err());
        assert!(Params {
            uniqueness: f32::NAN,
            ..good
        }
        .check(64, 48)
        .is_err());
    }
}
