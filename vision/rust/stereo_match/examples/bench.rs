//! Times the matcher on a synthetic pair:
//! `cargo run --release --example bench -p stereo_match -- [width height disparities paths threads runs]`

use std::time::Instant;

use stereo_match::{Matcher, Params};

fn main() {
    let args: Vec<usize> = std::env::args()
        .skip(1)
        .map(|arg| arg.parse().expect("numeric arguments"))
        .collect();
    let arg = |index: usize, default: usize| args.get(index).copied().unwrap_or(default);
    let (width, height) = (arg(0, 480), arg(1, 360));
    let threads = arg(
        4,
        std::thread::available_parallelism().map_or(1, |n| n.get()),
    );
    let runs = arg(5, 30);
    let params = Params {
        disparities: arg(2, 64),
        paths: arg(3, 3) as u8,
        p1: 8,
        p2: 64,
        uniqueness: 1.2,
    };

    let mut state = 0x2545_F491_4F6C_DD1Du64;
    let mut random = || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        (state >> 24) as u8
    };
    let left: Vec<u8> = (0..width * height).map(|_| random()).collect();
    let mut right = left.clone();
    for (y, row) in right.chunks_exact_mut(width).enumerate() {
        let shift = 10 + y * 20 / height;
        row.rotate_left(shift);
    }

    let mut matcher = Matcher::new(threads);
    let mut times_ms: Vec<f64> = (0..runs)
        .map(|_| {
            let start = Instant::now();
            std::hint::black_box(matcher.disparity(&left, &right, width, height, &params));
            start.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    times_ms.sort_by(f64::total_cmp);
    println!(
        "{width}x{height} {} disparities {} paths, {threads} threads: median {:.2} ms, min {:.2} ms, max {:.2} ms over {runs} runs",
        params.disparities,
        params.paths,
        times_ms[runs / 2],
        times_ms[0],
        times_ms[runs - 1]
    );
}
