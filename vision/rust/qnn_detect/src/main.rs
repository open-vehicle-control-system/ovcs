//! `qnn_detect <context.bin> [score_threshold] [--performance <profile>]
//! [--rpc-polling-us <us>]`: the Port behind `VisionCore.Detection.Backend.Qnn`. YOLOX on the
//! Hexagon NPU through QNN's HTP backend, from a context binary built for this chip and QAIRT
//! version, under a power vote (`qnn::Power`): the performance profile, burst by default, and
//! the RPC polling, 0 µs by default.
//! `qnn_detect --graph-names <model.dlc>` prints the DLC's graph names, one a line.
//! The environment's `LD_LIBRARY_PATH` holds `libQnnHtp.so` and
//! `libQnnSystem.so`, its `ADSP_LIBRARY_PATH` the HTP's DSP libraries.
//!
//! The model takes one 640x640 uint8 RGB image of pixel values and gives YOLOX's uint8
//! `boxes`, `scores` and `class_idx`; another model is refused at start (`model`).
//!
//! Records are `hailo_detect`'s (`detection::protocol`): a request carries a
//! sequence, the image's size, 1 (grey) or 3 (RGB) channels and its pixels;
//! the reply the detections in the image's pixels and, when the graph ran, its
//! time on the HTP from QNN's profile, or the wall time around its execution
//! when the profile is unavailable; or a LOG record.
//! Every minute, a LOG record gives each stage's mean time per request (`qnn::StageTimes`).

mod model;
mod yolox;

use std::process::exit;
use std::time::Instant;

use detection::letterbox::{letterbox_for, letterbox_into, Frame};
use detection::protocol::{detections_record, inference_micros, parse_request};
use framing::{LogLevel, Writer};
use model::Layout;
use qnn::port::{self, Clock, Start};
use qnn::{Power, TimeLog};
use yolox::{decode, Outputs, MODEL_SIZE};

const DEFAULT_SCORE_THRESHOLD: f32 = 0.4;
const NMS_IOU: f32 = 0.45;

/// Threads the letterbox splits its rows across.
const LETTERBOX_THREADS: usize = 3;

const NAME: &str = "qnn_detect";
const USAGE: &str = "usage: qnn_detect <context.bin> [score_threshold] \
                     [--performance <profile>] [--rpc-polling-us <us>] \
                     | --graph-names <model.dlc>";

fn main() {
    let Start {
        arguments,
        power,
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
    if let Err(message) = run(context_path, score_threshold, power, &writer) {
        port::log(&writer, LogLevel::Error, &message);
        exit(1);
    }
}

fn run(
    context_path: &str,
    score_threshold: f32,
    power: Power,
    writer: &Writer,
) -> Result<(), String> {
    let mut model = port::open_model(context_path, power, writer)?;

    let Layout {
        boxes,
        box_quantisation,
        scores,
        score_quantisation,
        classes,
    } = model::layout(&model.inputs, &model.outputs)?;

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

    let mut input = vec![0u8; model.inputs[0].bytes];
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
