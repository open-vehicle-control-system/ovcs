//! `hailo_detect <model.hef> [score_threshold]`: the Port behind `VisionCore.Inference.Hailo`.
//! The HEF carries its NMS in-graph, so this binary letterboxes pixels in and reads boxes back out.
//!
//! Request (stdin): u8 tag 1, u32 seq, u16 width, u16 height, u8 channels (1 gray, 3 BGR), pixels.
//! Response (stdout): u8 tag 1, u32 seq, u16 count, count × {u16 class_id, f32 score, x0, y0, x1, y1}
//! in the caller's pixel coordinates. Scalars are little-endian.

#[cfg(feature = "device")]
mod hailo;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod letterbox;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod nms;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod outcome;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod protocol;

use std::process::exit;

use framing::Writer;

const DEFAULT_SCORE_THRESHOLD: f32 = 0.4;

/// stderr, not LOG records: `VisionCore.Inference.Hailo` reads only detections records.
fn log(message: &str) {
    eprintln!("[hailo_detect] {message}");
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() < 2 {
        log("usage: hailo_detect <model.hef> [score_threshold]");
        exit(2);
    }
    let hef_path = &argv[1];
    let score_threshold = match argv.get(2).map(|s| s.parse::<f32>()) {
        None => DEFAULT_SCORE_THRESHOLD,
        Some(Ok(threshold)) => threshold,
        Some(Err(_)) => {
            log(&format!("bad score threshold {}", argv[2]));
            exit(2);
        }
    };

    // Before any HailoRT call: libhailort may log onto stdout.
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(_) => {
            log("could not dup stdout");
            exit(1);
        }
    };

    #[cfg(feature = "device")]
    exit(run(hef_path, score_threshold, &writer));

    #[cfg(not(feature = "device"))]
    {
        let _ = (hef_path, score_threshold, writer);
        log("built without the device feature");
        exit(1);
    }
}

#[cfg(feature = "device")]
fn run(hef_path: &str, score_threshold: f32, writer: &Writer) -> i32 {
    use letterbox::{letterbox_for, letterbox_into};
    use outcome::{reply_for, FrameOutcome, Reply};
    use protocol::{detections_record, parse_request};

    let mut detector = match hailo::Detector::open(hef_path) {
        Ok(detector) => detector,
        Err(message) => {
            log(&message);
            return 1;
        }
    };
    let model_size = detector.model_size;
    let class_count = detector.class_count;
    let output_floats = detector.output_bytes / std::mem::size_of::<f32>();

    log(&format!(
        "ready: {hef_path} {model_size}x{model_size}, {class_count} classes, threshold {score_threshold}"
    ));

    let mut model_input = vec![0u8; model_size as usize * model_size as usize * 3];
    let mut output = vec![0f32; detector.output_bytes.div_ceil(std::mem::size_of::<f32>())];
    let mut stdin = std::io::stdin().lock();

    while let Ok(Some(record)) = framing::read_record(&mut stdin) {
        let Some(request) = parse_request(&record) else {
            continue;
        };
        if let Err(message) = request.check() {
            log(&message);
            continue;
        }
        let (width, height) = (i32::from(request.width), i32::from(request.height));

        let b = letterbox_for(width, height, model_size);
        letterbox_into(
            request.pixels,
            width,
            height,
            request.channels,
            &mut model_input,
            model_size,
            &b,
        );

        let outcome = match detector.infer(&model_input, &mut output) {
            Ok(()) => FrameOutcome::Inferred,
            Err(failure) => {
                log(&failure.message);
                failure.outcome
            }
        };
        match reply_for(outcome) {
            Reply::Detections => {}
            // The Elixir side holds per-seq state until it gets an answer.
            Reply::Empty => {
                if writer
                    .write_record(&detections_record(request.seq, &[]))
                    .is_err()
                {
                    break;
                }
                continue;
            }
            Reply::EmptyThenExit => {
                log("vstreams may hold a frame in flight; exiting for a restart");
                let _ = writer.write_record(&detections_record(request.seq, &[]));
                return 1;
            }
        }

        let nms_output = &output[..output_floats];
        if let Some(dir) = std::env::var_os("HAILO_DEBUG_DUMP") {
            dump_debug(
                std::path::Path::new(&dir),
                &model_input,
                model_size,
                nms_output,
                class_count,
            );
        }

        let detections = nms::decode_nms_by_class(
            nms_output,
            class_count,
            width,
            height,
            &b,
            model_size,
            score_threshold,
        );
        if writer
            .write_record(&detections_record(request.seq, &detections))
            .is_err()
        {
            break;
        }
    }

    0
}

/// `HAILO_DEBUG_DUMP=<dir>`: the model input as a PPM and the head of the raw NMS output,
/// to see a wrong letterbox or a misread output layout.
#[cfg(feature = "device")]
fn dump_debug(
    dir: &std::path::Path,
    rgb: &[u8],
    size: i32,
    nms_output: &[f32],
    class_count: usize,
) {
    use std::fmt::Write as _;

    let mut ppm = format!("P6\n{size} {size}\n255\n").into_bytes();
    ppm.extend_from_slice(rgb);
    let _ = std::fs::write(dir.join("hailo_input.ppm"), ppm);

    // One line per class that reported any box, so a non-empty result is obvious
    // even when every score is below threshold.
    let mut text = String::new();
    let mut offset = 0;
    for class_id in 0..class_count {
        if offset >= nms_output.len() {
            break;
        }
        let count = nms_output[offset] as usize;
        offset += 1;
        let Some(end) = nms::class_end(offset, count) else {
            break;
        };
        if count > 0 && end <= nms_output.len() {
            let _ = write!(text, "class {class_id} count {count}:");
            for bbox in nms_output[offset..]
                .chunks_exact(nms::FLOATS_PER_BOX)
                .take(count.min(4))
            {
                let _ = write!(
                    text,
                    "  [y0={:.3} x0={:.3} y1={:.3} x1={:.3} s={:.3}]",
                    bbox[0], bbox[1], bbox[2], bbox[3], bbox[4]
                );
            }
            text.push('\n');
        }
        offset = end;
    }
    let _ = std::fs::write(dir.join("hailo_output.txt"), text);
}
