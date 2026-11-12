//! `qnn_segment <context.bin> <classes> [--performance <profile>]`: the Port behind
//! `VisionCore.Segmentation.Backend.Qnn`. A semantic segmentation model on the Hexagon NPU
//! through QNN's HTP backend, from a context binary built for this chip and QAIRT version,
//! scoring the `classes` classes the pipeline names, under the power vote of the performance
//! profile (`qnn::Performance`, burst by default). `qnn_segment --graph-names <model.dlc>`
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

use std::os::fd::AsFd;
use std::process::exit;
use std::time::Instant;

use framing::{log_record, LogLevel, Writer};
use model::Geometry;
use protocol::{labels_record, parse_request};
use qnn::{CommandLine, Performance, StageTimes, TimeLog, EXECUTION_STAGES, STAGE_TIMES_EVERY};

/// Room in the request pipe for a whole request, which the BEAM then writes in one go.
const REQUEST_PIPE_BYTES: usize = 4 << 20;

/// Threads the resize and the argmax each split their rows across.
const THREADS: usize = 3;

fn log(writer: &Writer, level: LogLevel, message: &str) {
    let _ = writer.write_record(&log_record(level, message));
}

/// A failure before stdout carries records goes to stderr.
fn exit_early(message: &str, status: i32) -> ! {
    eprintln!("qnn_segment: {message}");
    exit(status)
}

const USAGE: &str = "usage: qnn_segment <context.bin> <classes> [--performance <profile>] \
                     | --graph-names <model.dlc>";

fn main() {
    let command_line: Vec<String> = std::env::args().skip(1).collect();
    let (arguments, performance) = match qnn::command_line(&command_line) {
        Ok(CommandLine::GraphNames(dlc)) => match qnn::print_dlc_graph_names(dlc) {
            Ok(()) => exit(0),
            Err(message) => exit_early(&message, 1),
        },
        Ok(CommandLine::Serve {
            arguments,
            performance,
        }) => (arguments, performance),
        Err(message) => exit_early(&format!("{message}; {USAGE}"), 2),
    };
    let (context_path, classes) = match arguments {
        [context_path, classes] => match classes.parse::<usize>() {
            Ok(classes) => (context_path, classes),
            Err(_) => exit_early(&format!("classes: {classes} is not a count"), 2),
        },
        _ => exit_early(USAGE, 2),
    };

    // Before any QNN call: its libraries may log onto stdout.
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(error) => exit_early(&format!("stdout: {error}"), 1),
    };
    writer.log_panics();

    if let Err(message) = run(context_path, classes, performance, &writer) {
        log(&writer, LogLevel::Error, &message);
        exit(1);
    }
}

fn run(
    context_path: &str,
    expected_classes: usize,
    performance: Performance,
    writer: &Writer,
) -> Result<(), String> {
    match framing::enlarge_pipe(std::io::stdin().as_fd(), REQUEST_PIPE_BYTES) {
        Ok(bytes) => log(
            writer,
            LogLevel::Info,
            &format!("request pipe: {bytes} bytes"),
        ),
        Err(error) => log(
            writer,
            LogLevel::Warning,
            &format!("request pipe not enlarged: {error}"),
        ),
    }
    let binary = std::fs::read(context_path).map_err(|e| format!("{context_path}: {e}"))?;
    let mut model = qnn::Model::open(&binary, performance)?;
    drop(binary);
    match performance.outcome(model.power_vote_error.as_deref()) {
        Ok(line) => log(writer, LogLevel::Info, &line),
        Err(line) => log(writer, LogLevel::Warning, &line),
    }

    let Geometry {
        input_width,
        input_height,
        output_width,
        output_height,
        classes,
    } = model::geometry(&model.inputs, &model.outputs, expected_classes)?;

    log(
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
    let mut stdin = std::io::stdin().lock();
    let mut time_log = TimeLog::default();
    let mut record = Vec::new();
    let mut stage_times = StageTimes::new(
        &[
            &["idle", "read", "resize"],
            &EXECUTION_STAGES[..],
            &["argmax", "reply"],
        ]
        .concat(),
        STAGE_TIMES_EVERY,
        Instant::now(),
    );
    let mut mark = Instant::now();

    while let Ok(Some(length)) = framing::read_length(&mut stdin) {
        stage_times.lap("idle", &mut mark);
        if !matches!(
            framing::read_body_into(&mut stdin, length, &mut record),
            Ok(true)
        ) {
            break;
        }
        stage_times.lap("read", &mut mark);
        let Some(request) = parse_request(&record) else {
            continue;
        };
        let unanswered = || labels_record(request.sequence, 0, 0, &[], None);
        let reply = match request.check() {
            Err(message) => {
                log(writer, LogLevel::Warning, &message);
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
                stage_times.lap("resize", &mut mark);
                match model.execute(&mut [input.as_mut_slice()], &mut [scores.as_mut_slice()]) {
                    Ok(timing) => {
                        timing.add_to(&mut stage_times);
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
                        mark = Instant::now();
                        labels::argmax_into(&scores, classes, &mut labels, THREADS);
                        stage_times.lap("argmax", &mut mark);
                        labels_record(
                            request.sequence,
                            output_width,
                            output_height,
                            &labels,
                            Some(timing.micros),
                        )
                    }
                    Err(message) => {
                        log(writer, LogLevel::Error, &message);
                        unanswered()
                    }
                }
            }
        };
        if writer.write_record(&reply).is_err() {
            break;
        }
        stage_times.lap("reply", &mut mark);
        stage_times.count_request();
        if let Some(line) = stage_times.line(mark) {
            log(writer, LogLevel::Info, &line);
        }
    }
    Ok(())
}
