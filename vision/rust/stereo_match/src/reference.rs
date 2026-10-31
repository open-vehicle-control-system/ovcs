//! `NxStereo.sgm_n` transcribed step by step on full `i32` volumes, the
//! reference the optimised code is tested against.

use crate::Params;

const INVALID_KEY: u32 = 0xFFFF_FFFF;

pub fn neighbours() -> Vec<(i32, i32)> {
    let mut offsets = Vec::new();
    for dy in -3..=3 {
        for dx in -4..=4 {
            if dy != 0 && dx != 0 {
                offsets.push((dy, dx));
            }
        }
    }
    offsets
}

pub fn census(image: &[u8], width: usize, height: usize) -> Vec<u64> {
    let at = |y: i32, x: i32| {
        let y = y.clamp(0, height as i32 - 1) as usize;
        let x = x.clamp(0, width as i32 - 1) as usize;
        i32::from(image[y * width + x])
    };
    let mut features = vec![0u64; width * height];
    for y in 0..height as i32 {
        for x in 0..width as i32 {
            let centre = at(y, x);
            for (bit, (dy, dx)) in neighbours().into_iter().enumerate() {
                if at(y + dy, x + dx) + 1 < centre {
                    features[y as usize * width + x as usize] |= 1 << bit;
                }
            }
        }
    }
    features
}

/// `costs[(y * width + x) * disparities + d]`
pub fn matching_costs(
    left: &[u64],
    right: &[u64],
    width: usize,
    height: usize,
    disparities: usize,
) -> Vec<i32> {
    let mut costs = vec![0; width * height * disparities];
    for y in 0..height {
        for x in 0..width {
            for d in 0..disparities {
                let feature = if x >= d { right[y * width + x - d] } else { 0 };
                costs[(y * width + x) * disparities + d] =
                    (left[y * width + x] ^ feature).count_ones() as i32;
            }
        }
    }
    costs
}

/// One path: each pixel continues the path from `(y - dy, x - dx)`, from zero
/// where that lies outside the image. Pixels are visited so that the
/// predecessor is always done first.
fn path(
    costs: &[i32],
    width: usize,
    height: usize,
    disparities: usize,
    (dy, dx): (i32, i32),
    params: &Params,
) -> Vec<i32> {
    let (p1, p2) = (i32::from(params.p1), i32::from(params.p2));
    let mut paths = vec![0; costs.len()];
    let ys: Vec<i32> = if dy < 0 {
        (0..height as i32).rev().collect()
    } else {
        (0..height as i32).collect()
    };
    let xs: Vec<i32> = if dx < 0 {
        (0..width as i32).rev().collect()
    } else {
        (0..width as i32).collect()
    };
    for &y in &ys {
        for &x in &xs {
            let (py, px) = (y - dy, x - dx);
            let previous: Vec<i32> =
                if py >= 0 && py < height as i32 && px >= 0 && px < width as i32 {
                    let at = (py as usize * width + px as usize) * disparities;
                    paths[at..at + disparities].to_vec()
                } else {
                    vec![0; disparities]
                };
            let minimum = *previous.iter().min().unwrap();
            let a: Vec<i32> = previous.iter().map(|v| v - minimum).collect();
            let at = (y as usize * width + x as usize) * disparities;
            for d in 0..disparities {
                let lower = if d == 0 { p2 - p1 } else { a[d - 1] };
                let upper = if d == disparities - 1 {
                    p2 - p1
                } else {
                    a[d + 1]
                };
                paths[at + d] = a[d].min(p2).min(lower.min(upper) + p1) + costs[at + d];
            }
        }
    }
    paths
}

pub fn directions(paths: u8) -> Vec<(i32, i32)> {
    let mut directions = vec![(0, 1), (0, -1), (1, 0)];
    if paths == 8 {
        directions.extend([(-1, 0), (1, 1), (1, -1), (-1, 1), (-1, -1)]);
    }
    directions
}

pub fn aggregate(costs: &[i32], width: usize, height: usize, params: &Params) -> Vec<i32> {
    let mut sums = vec![0; costs.len()];
    for direction in directions(params.paths) {
        for (sum, value) in sums.iter_mut().zip(path(
            costs,
            width,
            height,
            params.disparities,
            direction,
            params,
        )) {
            *sum += value;
        }
    }
    sums
}

/// `(disparity, key)` per pixel.
pub fn select(sums: &[i32], width: usize, height: usize, params: &Params) -> (Vec<f32>, Vec<u32>) {
    let disparities = params.disparities;
    let mut disparity = vec![0.0; width * height];
    let mut keys = vec![0; width * height];
    for y in 0..height {
        for x in 0..width {
            let at = (y * width + x) * disparities;
            let values: Vec<i32> = (0..disparities)
                .map(|d| sums[at + d] + if d > x { 0x8000 } else { 0 })
                .collect();
            let minimum = *values.iter().min().unwrap();
            let winner = values.iter().position(|&v| v == minimum).unwrap() as i32;
            let second = (0..disparities as i32)
                .filter(|d| (d - winner).abs() > 1)
                .map(|d| values[d as usize])
                .min()
                .unwrap_or(i32::MAX);
            let lower = values[(winner - 1).max(0) as usize] as f32;
            let upper = values[(winner + 1).min(disparities as i32 - 1) as usize] as f32;
            let minimum_f = minimum as f32;
            let accepted = second as f32 > minimum_f * params.uniqueness;
            let denominator = lower + upper - 2.0 * minimum_f;
            let correction = ((lower - upper) / (2.0 * denominator.max(1.0))).clamp(-0.5, 0.5);
            let refine =
                denominator > 0.0 && winner > 0 && winner < (disparities as i32 - 1).min(x as i32);
            let value = winner as f32 + if refine { correction } else { 0.0 };
            let key = ((minimum as u32) << 16) | winner as u32;
            disparity[y * width + x] = if accepted { value } else { -1.0 };
            keys[y * width + x] = if accepted { key } else { INVALID_KEY };
        }
    }
    (disparity, keys)
}

pub fn consistency(
    disparity: &[f32],
    keys: &[u32],
    width: usize,
    height: usize,
    disparities: usize,
) -> Vec<f32> {
    let mut out = vec![0.0; width * height];
    for y in 0..height {
        let row = &keys[y * width..(y + 1) * width];
        let right: Vec<u32> = (0..width)
            .map(|rx| {
                (0..disparities)
                    .map(|d| {
                        let key = if rx + d < width {
                            row[rx + d]
                        } else {
                            INVALID_KEY
                        };
                        if key != INVALID_KEY && (key & 0xFFFF) as usize == d {
                            (key & 0xFFFF_0000) | (65_535 - d as u32)
                        } else {
                            INVALID_KEY
                        }
                    })
                    .min()
                    .unwrap()
            })
            .collect();
        let disagrees = |rx: i32, d: i32| {
            let inside = rx >= 0 && rx < width as i32;
            let found = right[rx.clamp(0, width as i32 - 1) as usize];
            let right_d = 65_535 - (found & 0xFFFF) as i32;
            inside && found != INVALID_KEY && (right_d - d).abs() > 1
        };
        for x in 0..width {
            let value = disparity[y * width + x];
            let (lo, hi) = (value.floor() as i32, value.ceil() as i32);
            let rejected = disagrees(x as i32 - lo, lo) && disagrees(x as i32 - hi, hi);
            out[y * width + x] = if value >= 0.0 && !rejected {
                value
            } else {
                -1.0
            };
        }
    }
    out
}

pub fn median3(image: &[f32], width: usize, height: usize) -> Vec<f32> {
    let at = |y: i32, x: i32| {
        image
            [y.clamp(0, height as i32 - 1) as usize * width + x.clamp(0, width as i32 - 1) as usize]
    };
    let mut out = vec![0.0; width * height];
    for y in 0..height as i32 {
        for x in 0..width as i32 {
            let mut values: Vec<f32> = (-1..=1)
                .flat_map(|dy| (-1..=1).map(move |dx| (dy, dx)))
                .map(|(dy, dx)| at(y + dy, x + dx))
                .collect();
            values.sort_by(f32::total_cmp);
            out[y as usize * width + x as usize] = values[4];
        }
    }
    out
}

pub fn sgm(left: &[u8], right: &[u8], width: usize, height: usize, params: &Params) -> Vec<f32> {
    let costs = matching_costs(
        &census(left, width, height),
        &census(right, width, height),
        width,
        height,
        params.disparities,
    );
    let sums = aggregate(&costs, width, height, params);
    let (disparity, keys) = select(&sums, width, height, params);
    median3(
        &consistency(&disparity, &keys, width, height, params.disparities),
        width,
        height,
    )
}
