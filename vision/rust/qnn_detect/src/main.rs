//! `qnn_detect <context.bin> [score_threshold] [--performance <profile>]`: the Port behind
//! `VisionCore.Detection.Backend.Qnn`. YOLOX on the Hexagon NPU through QNN's
//! HTP backend, from a context binary built for this chip and QAIRT version, under the
//! power vote of the performance profile (`qnn::Performance`, burst by default).
//! `qnn_detect --graph-names <model.dlc>` prints the DLC's graph names, one a line.
//! The environment's `LD_LIBRARY_PATH` holds `libQnnHtp.so` and
//! `libQnnSystem.so`, its `ADSP_LIBRARY_PATH` the HTP's DSP libraries.
//!
//! Records are `hailo_detect`'s (`detection::protocol`): a request carries a
//! sequence, the image's size, 1 (grey) or 3 (RGB) channels and its pixels;
//! the reply the detections in the image's pixels and, when the graph ran, its
//! time on the HTP from QNN's profile, or the wall time around its execution
//! when the profile is unavailable; or a LOG record.
//! Every minute, a LOG record gives each stage's mean time per request (`qnn::StageTimes`).

mod yolox;

use std::process::exit;
use std::time::Instant;

use detection::letterbox::{letterbox_for, letterbox_into, Frame};
use detection::protocol::{detections_record, inference_micros, parse_request};
use framing::{LogLevel, Writer};
use qnn::port::{self, Clock, Start};
use qnn::{Performance, TimeLog};
use yolox::{decode, Outputs, Quantisation, ANCHORS, MODEL_SIZE};

const DEFAULT_SCORE_THRESHOLD: f32 = 0.4;
const NMS_IOU: f32 = 0.45;

/// Threads the letterbox splits its rows across.
const LETTERBOX_THREADS: usize = 3;

const NAME: &str = "qnn_detect";
const USAGE: &str = "usage: qnn_detect <context.bin> [score_threshold] \
                     [--performance <profile>] | --graph-names <model.dlc>";

fn main() {
    let Start {
        arguments,
        performance,
        writer,
    } = port::start(NAME, USAGE);
    let Some(context_path) = arguments.first() else {
        port::exit_early(NAME, USAGE, 2);
    };
    let score_threshold = match arguments.get(1).map(|s| s.parse::<f32>()) {
        None => DEFAULT_SCORE_THRESHOLD,
        Some(Ok(threshold)) => threshold,
        Some(Err(_)) => port::exit_early(NAME, &format!("bad score threshold {}", arguments[1]), 2),
    };
    if let Err(message) = run(context_path, score_threshold, performance, &writer) {
        port::log(&writer, LogLevel::Error, &message);
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

fn run(
    context_path: &str,
    score_threshold: f32,
    performance: Performance,
    writer: &Writer,
) -> Result<(), String> {
    let mut model = port::open_model(context_path, performance, writer)?;

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

    port::log(
        writer,
        LogLevel::Info,
        &format!(
            "ready: {context_path}, graph {}, input {:?}, outputs {:?}, \
             boxes {box_quantisation:?}, scores {score_quantisation:?}, threshold {score_threshold}",
            model.graph_name,
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
    let mut time_log = TimeLog::default();
    let mut clock = Clock::new("letterbox", "decode", Instant::now());
    let mut stdin = std::io::stdin().lock();
    port::serve(&mut stdin, writer, &mut clock, |record, clock| {
        let request = parse_request(record)?;
        let (width, height) = (i32::from(request.width), i32::from(request.height));
        let letterbox = letterbox_for(width, height, MODEL_SIZE);
        let (detections, time) = match request.check() {
            Err(message) => {
                port::log(writer, LogLevel::Warning, &message);
                (Vec::new(), None)
            }
            Ok(()) => {
                letterbox_into(
                    &Frame {
                        pixels: request.pixels,
                        width,
                        height,
                        channels: request.channels,
                    },
                    &mut input,
                    MODEL_SIZE,
                    &letterbox,
                    LETTERBOX_THREADS,
                );
                clock.prepared();
                let mut outputs: Vec<&mut [u8]> = buffers
                    .iter_mut()
                    .map(|buffer| buffer.as_mut_slice())
                    .collect();
                match model.execute(&mut [input.as_mut_slice()], &mut outputs) {
                    Ok(timing) => {
                        port::log_execution(writer, &mut model, &mut time_log, &timing);
                        clock.executed(&timing);
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
                        clock.finished();
                        (
                            detections,
                            Some(inference_micros(u128::from(timing.micros))),
                        )
                    }
                    Err(message) => {
                        port::log(writer, LogLevel::Error, &message);
                        (Vec::new(), None)
                    }
                }
            }
        };
        Some(detections_record(request.sequence, &detections, time))
    })
}
