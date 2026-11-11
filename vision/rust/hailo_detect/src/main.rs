//! `hailo_detect <model.hef> [score_threshold]`: the Port behind `VisionCore.Detection.Backend.Hailo`.
//! The HEF carries its NMS in-graph, so this binary letterboxes pixels in and reads boxes back out.
//!
//! Request (stdin): u8 tag 1, u32 sequence, u16 width, u16 height, u8 channels (1 gray, 3 BGR), pixels.
//! Response (stdout): u8 tag 1, u32 sequence, u16 count, count × {u16 class_id, f32 score, x0, y0, x1, y1}
//! in the caller's pixel coordinates, then, when the frame was inferred, a u32 inference time
//! in µs (the input's write and the output's read); or a LOG record (`framing::log_record`).
//! Scalars are little-endian.

#[cfg(feature = "device")]
mod hailo;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod outcome;

#[cfg_attr(not(feature = "device"), allow(unused_imports))]
use detection::{letterbox, nms, protocol};

use std::process::exit;

use framing::{log_record, LogLevel, Writer};

const DEFAULT_SCORE_THRESHOLD: f32 = 0.4;

/// A LOG record, which `VisionCore.Detection.Backend.Hailo` hands to the Logger.
fn log(writer: &Writer, level: LogLevel, message: &str) {
    let _ = writer.write_record(&log_record(level, message));
}

/// A failure before stdout carries records goes to stderr.
fn exit_early(message: &str, status: i32) -> ! {
    eprintln!("hailo_detect: {message}");
    exit(status)
}

fn main() {
    let command_line: Vec<String> = std::env::args().collect();
    if command_line.len() < 2 {
        exit_early("usage: hailo_detect <model.hef> [score_threshold]", 2);
    }
    let hef_path = &command_line[1];
    let score_threshold = match command_line.get(2).map(|s| s.parse::<f32>()) {
        None => DEFAULT_SCORE_THRESHOLD,
        Some(Ok(threshold)) => threshold,
        Some(Err(_)) => exit_early(&format!("bad score threshold {}", command_line[2]), 2),
    };

    // Before any HailoRT call: libhailort may log onto stdout.
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(error) => exit_early(&format!("stdout: {error}"), 1),
    };
    writer.log_panics();

    #[cfg(feature = "device")]
    exit(run(hef_path, score_threshold, &writer));

    #[cfg(not(feature = "device"))]
    {
        let _ = (hef_path, score_threshold);
        log(&writer, LogLevel::Error, "built without the device feature");
        exit(1);
    }
}

#[cfg(feature = "device")]
fn run(hef_path: &str, score_threshold: f32, writer: &Writer) -> i32 {
    use letterbox::{letterbox_for, letterbox_into};
    use outcome::{reply_for, FrameOutcome, Reply};
    use protocol::{detections_record, inference_micros, parse_request};

    let mut detector = match hailo::Detector::open(hef_path) {
        Ok(detector) => detector,
        Err(message) => {
            log(writer, LogLevel::Error, &message);
            return 1;
        }
    };
    let model_size = detector.model_size;
    let class_count = detector.class_count;
    let output_floats = detector.output_bytes / std::mem::size_of::<f32>();

    log(
        writer,
        LogLevel::Info,
        &format!(
            "ready: {hef_path} {model_size}x{model_size}, {class_count} classes, threshold {score_threshold}"
        ),
    );

    let mut model_input = vec![0u8; model_size as usize * model_size as usize * 3];
    let mut output = vec![0f32; detector.output_bytes.div_ceil(std::mem::size_of::<f32>())];
    let mut stdin = std::io::stdin().lock();

    while let Ok(Some(record)) = framing::read_record(&mut stdin) {
        let Some(request) = parse_request(&record) else {
            continue;
        };
        let (width, height) = (i32::from(request.width), i32::from(request.height));
        let letterbox = letterbox_for(width, height, model_size);
        let mut inference_time = None;
        let outcome = match request.check() {
            Err(message) => {
                log(writer, LogLevel::Warning, &message);
                FrameOutcome::Rejected
            }
            Ok(()) => {
                letterbox_into(
                    request.pixels,
                    width,
                    height,
                    request.channels,
                    &mut model_input,
                    model_size,
                    &letterbox,
                );

                match detector.infer(&model_input, &mut output) {
                    Ok(elapsed) => {
                        inference_time = Some(inference_micros(elapsed.as_micros()));
                        FrameOutcome::Inferred
                    }
                    Err(failure) => {
                        log(writer, LogLevel::Error, &failure.message);
                        failure.outcome
                    }
                }
            }
        };
        match reply_for(outcome) {
            Reply::Detections => {}
            // The Elixir side holds per-sequence state until it gets an answer.
            Reply::Empty => {
                if writer
                    .write_record(&detections_record(request.sequence, &[], None))
                    .is_err()
                {
                    break;
                }
                continue;
            }
            Reply::EmptyThenExit => {
                log(
                    writer,
                    LogLevel::Warning,
                    "vstreams may hold a frame in flight; exiting for a restart",
                );
                let _ = writer.write_record(&detections_record(request.sequence, &[], None));
                return 1;
            }
        }

        let nms_output = &output[..output_floats];
        if let Some(dump_directory) = std::env::var_os("HAILO_DEBUG_DUMP") {
            dump_debug(
                std::path::Path::new(&dump_directory),
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
            &letterbox,
            model_size,
            score_threshold,
        );
        if writer
            .write_record(&detections_record(
                request.sequence,
                &detections,
                inference_time,
            ))
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
    dump_directory: &std::path::Path,
    rgb: &[u8],
    size: i32,
    nms_output: &[f32],
    class_count: usize,
) {
    use std::fmt::Write as _;

    let mut ppm = format!("P6\n{size} {size}\n255\n").into_bytes();
    ppm.extend_from_slice(rgb);
    let _ = std::fs::write(dump_directory.join("hailo_input.ppm"), ppm);

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
            for bounding_box in nms_output[offset..]
                .chunks_exact(nms::FLOATS_PER_BOX)
                .take(count.min(4))
            {
                let _ = write!(
                    text,
                    "  [y0={:.3} x0={:.3} y1={:.3} x1={:.3} s={:.3}]",
                    bounding_box[0],
                    bounding_box[1],
                    bounding_box[2],
                    bounding_box[3],
                    bounding_box[4]
                );
            }
            text.push('\n');
        }
        offset = end;
    }
    let _ = std::fs::write(dump_directory.join("hailo_output.txt"), text);
}
