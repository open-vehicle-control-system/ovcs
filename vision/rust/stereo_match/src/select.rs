//! The winner of each pixel, its uniqueness and subpixel refinement, as
//! `NxStereo`'s `select/3` computes them in `f32`.

pub const INVALID_KEY: u32 = u32::MAX;
/// Added to the costs of disparities past the image's left edge, so they never win.
const PAST_EDGE: u16 = 0x8000;
/// Disparities as `u16` lanes, for the winner's search to stay in vectors.
const INDICES: [u16; 128] = {
    let mut indices = [0; 128];
    let mut d = 0;
    while d < 128 {
        indices[d] = d as u16;
        d += 1;
    }
    indices
};

/// `(disparity, key)` of the pixel at column `x` from its summed path
/// costs: `(-1.0, INVALID_KEY)` unless the second-best cost, ignoring the
/// disparities next to the best one, exceeds the best times `uniqueness`.
/// The key holds the best cost in its high 16 bits, the winner in its low 16.
#[inline(always)]
pub fn select<const D: usize>(sums: &[u16; D], x: usize, uniqueness: f32) -> (f32, u32) {
    let Lowest {
        minimum,
        winner,
        second,
        lower,
        upper,
    } = lowest::<D>(sums, x);
    let (lower, upper) = (f32::from(lower), f32::from(upper));

    // Without branches: whether a match is kept is as hard to predict as a coin toss.
    let minimum_f = f32::from(minimum);
    let accepted = f32::from(second) > minimum_f * uniqueness;
    let denominator = lower + upper - 2.0 * minimum_f;
    let refine = (denominator > 0.0) & (winner > 0) & (winner < (D - 1).min(x));
    let correction = ((lower - upper) / (2.0 * denominator.max(1.0))).clamp(-0.5, 0.5);
    let disparity = winner as f32 + if refine { correction } else { 0.0 };
    let key = (u32::from(minimum) << 16) | winner as u32;
    if accepted {
        (disparity, key)
    } else {
        (-1.0, INVALID_KEY)
    }
}

/// A pixel's costs, those past the image's edge raised, as `select` reads
/// them: the lowest, the lowest disparity that has it, the lowest of the
/// others but the winner's neighbours, and the costs of the disparities
/// below and above the winner, within the range.
#[derive(Debug, PartialEq)]
struct Lowest {
    minimum: u16,
    winner: usize,
    second: u16,
    lower: u16,
    upper: u16,
}

/// The cost of disparity `d` at column `x`.
#[cfg(target_arch = "aarch64")]
#[inline(always)]
fn cost<const D: usize>(sums: &[u16; D], x: usize, d: usize) -> u16 {
    sums[d] + if x < D - 1 && d > x { PAST_EDGE } else { 0 }
}

/// The disparities next to the winner, within the range.
#[inline(always)]
fn neighbours<const D: usize>(winner: usize) -> (usize, usize) {
    (winner.saturating_sub(1), (winner + 1).min(D - 1))
}

#[cfg(any(not(target_arch = "aarch64"), test))]
#[inline(always)]
fn lowest_lanes<const D: usize>(sums: &[u16; D], x: usize) -> Lowest {
    let mut values = *sums;
    if x < D - 1 {
        let x = x as u16;
        for (value, &d) in values.iter_mut().zip(&INDICES) {
            *value += if d > x { PAST_EDGE } else { 0 };
        }
    }
    let minimum = lanes_min::<D>(&values, |_d, value| value);
    let winner = lanes_min::<D>(
        &values,
        |d, value| if value == minimum { d } else { u16::MAX },
    ) as usize;
    let (below, above) = neighbours::<D>(winner);
    let (start, span) = (below as u16, (above - below) as u16);
    let second = lanes_min::<D>(&values, |d, value| {
        if d.wrapping_sub(start) <= span {
            u16::MAX
        } else {
            value
        }
    });
    Lowest {
        minimum,
        winner,
        second,
        lower: values[below],
        upper: values[above],
    }
}

#[cfg(not(target_arch = "aarch64"))]
use lowest_lanes as lowest;

/// `lowest_lanes` in NEON: LLVM keeps its index comparisons out of vectors.
#[cfg(target_arch = "aarch64")]
#[inline(always)]
fn lowest<const D: usize>(sums: &[u16; D], x: usize) -> Lowest {
    use std::arch::aarch64::*;

    const { assert!(D.is_multiple_of(LANES) && D <= INDICES.len()) };
    let chunks = D / LANES;
    // SAFETY: NEON is part of AArch64, and every load reads within `sums`
    // or `INDICES`, both at least `D` long.
    unsafe {
        let index = |chunk: usize| vld1q_u16(INDICES.as_ptr().add(chunk * LANES));
        let past_edge = vdupq_n_u16(if x < D - 1 { PAST_EDGE } else { 0 });
        let column = vdupq_n_u16(x.min(D) as u16);
        let mut values = [vdupq_n_u16(0); 128 / LANES];
        let mut lowest = vdupq_n_u16(u16::MAX);
        for (chunk, value) in values.iter_mut().enumerate().take(chunks) {
            let sum = vld1q_u16(sums.as_ptr().add(chunk * LANES));
            let past = vandq_u16(vcgtq_u16(index(chunk), column), past_edge);
            *value = vaddq_u16(sum, past);
            lowest = vminq_u16(lowest, *value);
        }
        let minimum = vminvq_u16(lowest);

        let mut first = vdupq_n_u16(u16::MAX);
        for (chunk, &value) in values.iter().enumerate().take(chunks) {
            let tied = vceqq_u16(value, vdupq_n_u16(minimum));
            first = vminq_u16(first, vornq_u16(index(chunk), tied));
        }
        let winner = usize::from(vminvq_u16(first));

        let (below, above) = neighbours::<D>(winner);
        let (start, span) = (
            vdupq_n_u16(below as u16),
            vdupq_n_u16((above - below) as u16),
        );
        let mut others = vdupq_n_u16(u16::MAX);
        for (chunk, &value) in values.iter().enumerate().take(chunks) {
            let excluded = vcleq_u16(vsubq_u16(index(chunk), start), span);
            others = vminq_u16(others, vorrq_u16(value, excluded));
        }
        Lowest {
            minimum,
            winner,
            second: vminvq_u16(others),
            lower: cost::<D>(sums, x, below),
            upper: cost::<D>(sums, x, above),
        }
    }
}

const LANES: usize = 8;

/// The lowest `lane(d, values[d])`, folded over 8 lanes, the width of a
/// 128-bit vector register.
#[cfg(any(not(target_arch = "aarch64"), test))]
#[inline(always)]
fn lanes_min<const D: usize>(values: &[u16; D], lane: impl Fn(u16, u16) -> u16) -> u16 {
    let mut lowest = [u16::MAX; LANES];
    for (chunk, indices) in values.chunks_exact(LANES).zip(INDICES.chunks_exact(LANES)) {
        for i in 0..LANES {
            lowest[i] = lowest[i].min(lane(indices[i], chunk[i]));
        }
    }
    lowest.into_iter().fold(u16::MAX, u16::min)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reference;
    use crate::Params;

    fn select_reference(sums: &[u16; 64], x: usize, uniqueness: f32) -> (f32, u32) {
        let width = x + 1;
        let mut volume = vec![0; width * 64];
        volume[x * 64..].copy_from_slice(&sums.map(i32::from));
        let params = Params {
            disparities: 64,
            paths: 3,
            p1: 1,
            p2: 2,
            uniqueness,
        };
        let (disparity, keys) = reference::select(&volume, width, 1, &params);
        (disparity[x], keys[x])
    }

    #[test]
    fn matches_the_reference_on_random_and_tied_costs() {
        let mut random = crate::tests::Random::new(3);
        for case in 0..5_000 {
            let spread = [3, 20, 1016][case % 3];
            let sums: [u16; 64] = std::array::from_fn(|_| (random.next() % spread) as u16);
            let x = (random.next() % 80) as usize;
            for uniqueness in [1.0, 1.0526316, 1.2] {
                let (got, want) = (
                    select::<64>(&sums, x, uniqueness),
                    select_reference(&sums, x, uniqueness),
                );
                assert_eq!(
                    (got.0.to_bits(), got.1),
                    (want.0.to_bits(), want.1),
                    "{sums:?} at {x}"
                );
            }
        }
    }

    #[test]
    fn the_target_s_search_matches_the_portable_one() {
        fn check<const D: usize>(random: &mut crate::tests::Random) {
            for case in 0..5_000 {
                let spread = [2, 20, 1016][case % 3];
                let sums: [u16; D] = std::array::from_fn(|_| (random.next() % spread) as u16);
                let x = (random.next() % (D as u64 + 20)) as usize;
                assert_eq!(
                    lowest::<D>(&sums, x),
                    lowest_lanes::<D>(&sums, x),
                    "{sums:?} at {x}"
                );
            }
        }
        let mut random = crate::tests::Random::new(9);
        check::<64>(&mut random);
        check::<128>(&mut random);
    }

    #[test]
    fn ties_go_to_the_lower_disparity_and_the_edge_is_respected() {
        let mut sums = [100u16; 64];
        sums[10] = 5;
        sums[11] = 5;
        assert_eq!(select::<64>(&sums, 63, 1.0).1 & 0xFFFF, 10);
        sums[3] = 1;
        assert_eq!(select::<64>(&sums, 63, 1.0).1 & 0xFFFF, 3);
        sums[0] = 50;
        assert_eq!(
            select::<64>(&sums, 2, 1.0).1 & 0xFFFF,
            0,
            "disparities past x lose"
        );
    }
}
