//! `qnn_detect <context.bin> [score_threshold]`: the Port behind
//! `VisionCore.Detection.Backend.Qnn`. YOLOX on the Hexagon NPU through QNN's
//! HTP backend, from a context binary built for this chip and QAIRT version.
//! The environment's `LD_LIBRARY_PATH` holds `libQnnHtp.so` and
//! `libQnnSystem.so`, its `ADSP_LIBRARY_PATH` the HTP's DSP libraries.
//!
//! Records are `hailo_detect`'s (`detection::protocol`): a request carries a
//! sequence, the image's size, 1 (grey) or 3 (BGR) channels and its pixels;
//! the reply the detections in the image's pixels and, when the graph ran, its
//! time on the HTP from QNN's profile, or the wall time around its execution
//! when the profile is unavailable; or a LOG record.

mod yolox;

use std::process::exit;

use detection::letterbox::{letterbox_for, letterbox_into};
use detection::protocol::{detections_record, inference_micros, parse_request};
use framing::{log_record, LogLevel, Writer};
use qnn::TimeLog;
use yolox::{decode, Outputs, Quantisation, ANCHORS, MODEL_SIZE};

const DEFAULT_SCORE_THRESHOLD: f32 = 0.4;
const NMS_IOU: f32 = 0.45;

fn log(writer: &Writer, level: LogLevel, message: &str) {
    let _ = writer.write_record(&log_record(level, message));
}

/// A failure before stdout carries records goes to stderr.
fn exit_early(message: &str, status: i32) -> ! {
    eprintln!("qnn_detect: {message}");
    exit(status)
}

fn main() {
    let command_line: Vec<String> = std::env::args().collect();
    if command_line.len() < 2 {
        exit_early("usage: qnn_detect <context.bin> [score_threshold]", 2);
    }
    let context_path = &command_line[1];
    let score_threshold = match command_line.get(2).map(|s| s.parse::<f32>()) {
        None => DEFAULT_SCORE_THRESHOLD,
        Some(Ok(threshold)) => threshold,
        Some(Err(_)) => exit_early(&format!("bad score threshold {}", command_line[2]), 2),
    };

    // Before any QNN call: its libraries may log onto stdout.
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(error) => exit_early(&format!("stdout: {error}"), 1),
    };
    writer.log_panics();

    if let Err(message) = run(context_path, score_threshold, &writer) {
        log(&writer, LogLevel::Error, &message);
        exit(1);
    }
}

/// The output tensor named `name`, which must hold `bytes` bytes.
fn output_index(model: &qnn::Model, name: &str, bytes: usize) -> Result<usize, String> {
    let index = model
        .outputs
        .iter()
        .position(|tensor| tensor.name == name)
        .ok_or_else(|| format!("the model has no output {name}"))?;
    match model.outputs[index].bytes {
        actual if actual == bytes => Ok(index),
        actual => Err(format!("output {name} holds {actual} bytes, not {bytes}")),
    }
}

fn quantisation(model: &qnn::Model, index: usize) -> Result<Quantisation, String> {
    let tensor = &model.outputs[index];
    let (scale, offset) = tensor
        .scale_offset
        .ok_or_else(|| format!("output {} is not quantised", tensor.name))?;
    Ok(Quantisation {
        scale,
        zero_point: -offset,
    })
}

fn run(context_path: &str, score_threshold: f32, writer: &Writer) -> Result<(), String> {
    let binary = std::fs::read(context_path).map_err(|e| format!("{context_path}: {e}"))?;
    let mut model = qnn::Model::open(&binary)?;
    drop(binary);

    let input_bytes = (MODEL_SIZE * MODEL_SIZE * 3) as usize;
    match model.inputs.as_slice() {
        [input] if input.bytes == input_bytes => {}
        _ => {
            return Err(format!(
                "the model takes {} inputs, not one {MODEL_SIZE}x{MODEL_SIZE} RGB image",
                model.inputs.len()
            ))
        }
    }
    let boxes = output_index(&model, "boxes", ANCHORS * 4)?;
    let scores = output_index(&model, "scores", ANCHORS)?;
    let classes = output_index(&model, "class_idx", ANCHORS)?;
    let (box_quantisation, score_quantisation) =
        (quantisation(&model, boxes)?, quantisation(&model, scores)?);

    log(
        writer,
        LogLevel::Info,
        &format!(
            "ready: {context_path}, input {:?}, outputs {:?}, boxes {box_quantisation:?}, \
             scores {score_quantisation:?}, threshold {score_threshold}",
            model.inputs[0].dimensions,
            model
                .outputs
                .iter()
                .map(|t| (t.name.as_str(), &t.dimensions))
                .collect::<Vec<_>>()
        ),
    );

    let mut input = vec![0u8; input_bytes];
    let mut buffers: Vec<Vec<u8>> = model
        .outputs
        .iter()
        .map(|tensor| vec![0u8; tensor.bytes])
        .collect();
    let mut stdin = std::io::stdin().lock();
    let mut time_log = TimeLog::default();

    while let Ok(Some(record)) = framing::read_record(&mut stdin) {
        let Some(request) = parse_request(&record) else {
            continue;
        };
        let (width, height) = (i32::from(request.width), i32::from(request.height));
        let letterbox = letterbox_for(width, height, MODEL_SIZE);
        let (detections, time) = match request.check() {
            Err(message) => {
                log(writer, LogLevel::Warning, &message);
                (Vec::new(), None)
            }
            Ok(()) => {
                letterbox_into(
                    request.pixels,
                    width,
                    height,
                    request.channels,
                    &mut input,
                    MODEL_SIZE,
                    &letterbox,
                );
                let mut outputs: Vec<&mut [u8]> = buffers
                    .iter_mut()
                    .map(|buffer| buffer.as_mut_slice())
                    .collect();
                match model.execute(&mut [input.as_mut_slice()], &mut outputs) {
                    Ok(timing) => {
                        if let Some(report) = model.take_profile_report() {
                            log(
                                writer,
                                LogLevel::Info,
                                &format!("first execution's profile events: {report}"),
                            );
                        }
                        if let Some(message) =
                            time_log.message(timing.source, model.profile_error.as_deref())
                        {
                            log(writer, LogLevel::Info, &message);
                        }
                        let detections = decode(
                            &Outputs {
                                boxes: &buffers[boxes],
                                box_quantisation,
                                scores: &buffers[scores],
                                score_quantisation,
                                classes: &buffers[classes],
                            },
                            score_threshold,
                            NMS_IOU,
                            &letterbox,
                        );
                        (
                            detections,
                            Some(inference_micros(u128::from(timing.micros))),
                        )
                    }
                    Err(message) => {
                        log(writer, LogLevel::Error, &message);
                        (Vec::new(), None)
                    }
                }
            }
        };
        if writer
            .write_record(&detections_record(request.sequence, &detections, time))
            .is_err()
        {
            break;
        }
    }
    Ok(())
}
