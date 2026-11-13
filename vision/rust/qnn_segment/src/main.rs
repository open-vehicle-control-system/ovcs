//! `qnn_segment <context.bin> <classes> [--performance <profile>] [--rpc-polling-us <us>]`:
//! the Port behind `VisionCore.Segmentation.Backend.Qnn`. A semantic segmentation model on the
//! Hexagon NPU through QNN's HTP backend, from a context binary built for this chip and QAIRT
//! version, scoring the `classes` classes the pipeline names, under a power vote
//! (`qnn::Power`): the performance profile, burst by default, and the RPC polling, 0 µs by
//! default. `qnn_segment --graph-names <model.dlc>`
//! prints the DLC's graph names, one a line. The environment's `LD_LIBRARY_PATH` holds
//! `libQnnHtp.so` and `libQnnSystem.so`, its `ADSP_LIBRARY_PATH` the HTP's DSP libraries.
//!
//! The model takes one `[1, H, W, 3]` uint8 RGB image of pixel values, unquantised or quantised
//! with a scale of 1/255 and an offset of 0, and gives one `[1, H, W, C]` uint8 grid of C scores
//! per cell, C being `classes`; another model is refused at start. A request (`protocol`)
//! carries an RGB image and a band of its rows; the band, resized to the model's input, is
//! inferred, and the reply carries each cell's class, the highest of its scores, and, when the
//! graph ran, its time on the HTP from QNN's profile, or the wall time around its execution when
//! the profile is unavailable; or a LOG record.
//! Every minute, a LOG record gives each stage's mean time per request (`qnn::StageTimes`).

mod band;
mod labels;
mod model;
mod protocol;

use std::process::exit;
use std::time::Instant;

use framing::{LogLevel, Writer};
use model::Geometry;
use protocol::{labels_record, parse_request};
use qnn::port::{self, Clock, Start};
use qnn::{Power, TimeLog};

/// Threads the resize and the argmax each split their rows across.
const THREADS: usize = 3;

const NAME: &str = "qnn_segment";
const USAGE: &str = "usage: qnn_segment <context.bin> <classes> [--performance <profile>] \
                     [--rpc-polling-us <us>] | --graph-names <model.dlc>";

fn main() {
    let Start {
        arguments,
        power,
        writer,
    } = port::start(NAME, USAGE);
    let (context_path, classes) = match &arguments[..] {
        [context_path, classes] => match classes.parse::<usize>() {
            Ok(classes) => (context_path, classes),
            Err(_) => port::exit_early(NAME, &format!("classes: {classes} is not a count"), 2),
        },
        _ => port::exit_early(NAME, USAGE, 2),
    };
    if let Err(message) = run(context_path, classes, power, &writer) {
        port::log(&writer, LogLevel::Error, &message);
        exit(1);
    }
}

fn run(
    context_path: &str,
    expected_classes: usize,
    power: Power,
    writer: &Writer,
) -> Result<(), String> {
    let mut model = port::open_model(context_path, power, writer)?;

    let Geometry {
        input_width,
        input_height,
        output_width,
        output_height,
        classes,
    } = model::geometry(&model.inputs, &model.outputs, expected_classes)?;

    port::log(
        writer,
        LogLevel::Info,
        &format!(
            "ready: {context_path}, graph {}, input {} {:?} quantisation {:?}, output {} {:?} \
             quantisation {:?}",
            model.graph_name,
            model.inputs[0].name,
            model.inputs[0].dimensions,
            model.inputs[0].scale_offset,
            model.outputs[0].name,
            model.outputs[0].dimensions,
            model.outputs[0].scale_offset,
        ),
    );

    let mut input = vec![0u8; model.inputs[0].bytes];
    let mut scores = vec![0u8; model.outputs[0].bytes];
    let mut labels = vec![0u8; usize::from(output_width) * usize::from(output_height)];
    let mut time_log = TimeLog::default();
    let mut clock = Clock::new("resize", "argmax", Instant::now());
    let mut stdin = std::io::stdin().lock();
    port::serve(&mut stdin, writer, &mut clock, |record, clock| {
        let request = parse_request(record)?;
        let unanswered = || labels_record(request.sequence, 0, 0, &[], None);
        let reply = match request.check() {
            Err(message) => {
                port::log(writer, LogLevel::Warning, &message);
                unanswered()
            }
            Ok(()) => {
                let top = usize::from(request.band_top);
                band::resize_band(
                    request.pixels,
                    usize::from(request.width),
                    top..top + usize::from(request.band_height),
                    &mut input,
                    input_width,
                    input_height,
                    THREADS,
                );
                clock.prepared();
                match model.execute(&mut [input.as_mut_slice()], &mut [scores.as_mut_slice()]) {
                    Ok(timing) => {
                        port::log_execution(writer, &mut model, &mut time_log, &timing);
                        clock.executed(&timing);
                        labels::argmax_into(&scores, classes, &mut labels, THREADS);
                        clock.finished();
                        labels_record(
                            request.sequence,
                            output_width,
                            output_height,
                            &labels,
                            Some(timing.micros),
                        )
                    }
                    Err(message) => {
                        port::log(writer, LogLevel::Error, &message);
                        unanswered()
                    }
                }
            }
        };
        Some(reply)
    })
}
