//! libSGM's normalized path recurrence, along rows and in sweeps down or up
//! the image.
//!
//! A path's costs are at most `p2 + 48 <= 127`, so they are bytes, and two
//! paths add up within a byte. A path state is `D + 2` bytes: the `D` costs
//! between two 255 sentinels, which stand for the `p2 - p1` libSGM pads with,
//! as both only ever lose to the `p2` jump.

use crate::parallel::{on_threads, Backoff, Chunks, Shared};

pub const SENTINEL: u8 = u8::MAX;
/// The largest padded state, for 128 disparities.
pub const MAX_STATE: usize = 130;

/// The next state of a path from its `previous` one, whose lowest cost is
/// `previous_minimum`, and the matching `costs`; returns the next lowest
/// cost. Only `next[1..=D]` is written.
#[inline(always)]
pub fn step<const D: usize>(
    previous: &[u8],
    previous_minimum: u8,
    costs: &[u8],
    next: &mut [u8],
    p1: u8,
    p2: u8,
) -> u8 {
    let previous = &previous[..D + 2];
    let costs: &[u8; D] = costs[..D].try_into().unwrap();
    let next: &mut [u8; D] = (&mut next[1..D + 1]).try_into().unwrap();
    let jump = previous_minimum + p2;
    let mut minimum = u8::MAX;
    for d in 0..D {
        let neighbour = previous[d].min(previous[d + 2]).saturating_add(p1);
        let value = previous[d + 1].min(jump).min(neighbour) - previous_minimum + costs[d];
        next[d] = value;
        minimum = minimum.min(value);
    }
    minimum
}

/// A path state before the first step: zero costs.
pub fn reset_state<const D: usize>(state: &mut [u8]) {
    state[0] = SENTINEL;
    state[1..D + 1].fill(0);
    state[D + 1] = SENTINEL;
}

/// `out[x * D + d]`, the sum of the left-to-right and right-to-left paths of
/// one row of `costs`. The two paths are followed in the same loop, as
/// independent chains, into `out` and `backward`, which is scratch space.
pub fn horizontal_row<const D: usize>(
    costs: &[u8],
    out: &mut [u8],
    backward: &mut [u8],
    p1: u8,
    p2: u8,
) {
    let width = costs.len() / D;
    let mut states = [[0u8; MAX_STATE]; 4];
    for state in &mut states {
        reset_state::<D>(state);
    }
    let [mut forward_previous, mut forward_next, mut backward_previous, mut backward_next] =
        states.each_mut();
    let (mut forward_minimum, mut backward_minimum) = (0, 0);
    for x in 0..width {
        let back_x = width - 1 - x;
        forward_minimum = step::<D>(
            &forward_previous[..],
            forward_minimum,
            &costs[x * D..],
            &mut forward_next[..],
            p1,
            p2,
        );
        backward_minimum = step::<D>(
            &backward_previous[..],
            backward_minimum,
            &costs[back_x * D..],
            &mut backward_next[..],
            p1,
            p2,
        );
        out[x * D..(x + 1) * D].copy_from_slice(&forward_next[1..D + 1]);
        backward[back_x * D..(back_x + 1) * D].copy_from_slice(&backward_next[1..D + 1]);
        std::mem::swap(&mut forward_previous, &mut forward_next);
        std::mem::swap(&mut backward_previous, &mut backward_next);
    }
    for (sum, &cost) in out[..width * D].iter_mut().zip(&backward[..width * D]) {
        *sum += cost;
    }
}

/// The scratch space of a sweep, kept from one pair to the next.
#[derive(Default)]
pub struct SweepBuffers {
    states: Vec<u8>,
    minimums: Vec<u8>,
}

/// Rows a thread does on a chunk before it looks for other work.
const ROWS_PER_CLAIM: usize = 8;

/// The order a sweep visits rows in, and the column offsets of the paths it
/// follows: a path at `x` continues the one at `x - offset` on the row
/// before, from zero outside the image.
pub struct Sweep<'a, const N: usize> {
    pub down: bool,
    pub offsets: [isize; N],
    pub width: usize,
    pub height: usize,
    pub costs: &'a [u8],
    pub p1: u8,
    pub p2: u8,
    pub threads: usize,
}

impl<const N: usize> Sweep<'_, N> {
    /// Runs the paths over the image, a column chunk and a row at a time,
    /// and calls `finish(y, x, paths)` with each pixel's new path costs. A
    /// chunk whose paths cross columns does a row once the chunks beside it
    /// have done the row before, which is also when they no longer read the
    /// states it overwrites.
    pub fn run<const D: usize, F>(&self, buffers: &mut SweepBuffers, finish: F)
    where
        F: Fn(usize, usize, [&[u8]; N]) + Sync,
    {
        let (width, height) = (self.width, self.height);
        let slots = width + 2;
        let stride = D + 2;
        buffers.states.resize(N * 2 * slots * stride, 0);
        buffers.minimums.clear();
        buffers.minimums.resize(N * 2 * slots, 0);
        for state in buffers.states.chunks_exact_mut(stride) {
            reset_state::<D>(state);
        }
        let states = Shared::new(&mut buffers.states);
        let minimums = Shared::new(&mut buffers.minimums);
        let crosses = self.offsets.iter().any(|&offset| offset != 0);
        let chunks = Chunks::new(width, self.threads);
        let last = chunks.count() - 1;
        let slot =
            |path: usize, parity: usize, padded_x: usize| (path * 2 + parity) * slots + padded_x;
        let ready = |chunk: usize, row: usize| {
            row < height
                && (!crosses
                    || ((chunk == 0 || chunks.progress(chunk - 1) >= row)
                        && (chunk == last || chunks.progress(chunk + 1) >= row)))
        };

        let sweep_row = |chunk: usize, row: usize| {
            let y = if self.down { row } else { height - 1 - row };
            let (current, previous) = (row % 2, 1 - row % 2);
            for x in chunks.columns(chunk) {
                let costs = &self.costs[(y * width + x) * D..][..D];
                let paths: [&[u8]; N] = std::array::from_fn(|path| {
                    let source = slot(
                        path,
                        previous,
                        (x as isize + 1 - self.offsets[path]) as usize,
                    );
                    let target = slot(path, current, x + 1);
                    // SAFETY: the chunk's own columns are written by the thread
                    // holding it; the previous row's states it reads beside
                    // them are not written until it has done this row.
                    unsafe {
                        let previous_state = states.slice(source * stride..(source + 1) * stride);
                        let next_state = states.slice_mut(target * stride..(target + 1) * stride);
                        let previous_minimum = minimums.slice(source..source + 1)[0];
                        minimums.slice_mut(target..target + 1)[0] = step::<D>(
                            previous_state,
                            previous_minimum,
                            costs,
                            next_state,
                            self.p1,
                            self.p2,
                        );
                        &*(&next_state[1..D + 1] as *const [u8])
                    }
                });
                finish(y, x, paths);
            }
        };

        let threads = self.threads.min(chunks.count());
        let work = |thread: usize| {
            let mut backoff = Backoff::default();
            loop {
                let mut progressed = false;
                for offset in 0..chunks.count() {
                    let chunk = (thread * chunks.count() / threads + offset) % chunks.count();
                    if !ready(chunk, chunks.progress(chunk)) || !chunks.try_claim(chunk) {
                        continue;
                    }
                    let mut row = chunks.progress(chunk);
                    let first = row;
                    while ready(chunk, row) && row - first < ROWS_PER_CLAIM {
                        sweep_row(chunk, row);
                        row += 1;
                        chunks.set_progress(chunk, row);
                    }
                    chunks.release(chunk);
                    progressed |= row > first;
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
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The recurrence as `NxStereo`'s `scan/3` writes it.
    fn reference_step(previous: &[i32], costs: &[u8], p1: i32, p2: i32) -> Vec<i32> {
        let minimum = *previous.iter().min().unwrap();
        let a: Vec<i32> = previous.iter().map(|v| v - minimum).collect();
        let last = a.len() - 1;
        (0..a.len())
            .map(|d| {
                let lower = if d == 0 { p2 - p1 } else { a[d - 1] };
                let upper = if d == last { p2 - p1 } else { a[d + 1] };
                a[d].min(p2).min(lower.min(upper) + p1) + i32::from(costs[d])
            })
            .collect()
    }

    #[test]
    fn step_follows_the_reference_recurrence_at_its_bounds() {
        let mut random = crate::tests::Random::new(9);
        for (p1, p2) in [(0u8, 1u8), (8, 64), (78, 79)] {
            let mut previous = [0u8; MAX_STATE];
            reset_state::<64>(&mut previous);
            let mut minimum = 0;
            for _ in 0..200 {
                let costs: Vec<u8> = (0..64).map(|_| (random.next() % 49) as u8).collect();
                let want = reference_step(
                    &previous[1..65]
                        .iter()
                        .map(|&v| i32::from(v))
                        .collect::<Vec<_>>(),
                    &costs,
                    p1.into(),
                    p2.into(),
                );
                let mut next = [0u8; MAX_STATE];
                reset_state::<64>(&mut next);
                minimum = step::<64>(&previous, minimum, &costs, &mut next, p1, p2);
                let got: Vec<i32> = next[1..65].iter().map(|&v| i32::from(v)).collect();
                assert_eq!(got, want);
                assert_eq!(i32::from(minimum), *want.iter().min().unwrap());
                assert!(want.iter().all(|&v| v <= i32::from(p2) + 48));
                previous = next;
            }
        }
    }
}
