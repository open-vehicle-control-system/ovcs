//! `qnn_segment <context.bin>`: the Port behind `VisionCore.Segmentation.Backend.Qnn`. A semantic
//! segmentation model on the Hexagon NPU through QNN's HTP backend, from a context binary
//! built for this chip and QAIRT version. The environment's `LD_LIBRARY_PATH` holds
//! `libQnnHtp.so` and `libQnnSystem.so`, its `ADSP_LIBRARY_PATH` the HTP's DSP libraries.
//!
//! The model takes one `[1, H, W, 3]` uint8 RGB image of pixel values and gives one
//! `[1, H, W, C]` uint8 grid of C scores per cell. A request (`protocol`) carries an RGB image
//! and a band of its rows; the band, resized to the model's input, is inferred, and the reply
//! carries each cell's class, the highest of its scores, and, when the graph ran, its time on
//! the HTP from QNN's profile, or the wall time around its execution when the profile is
//! unavailable; or a LOG record.

mod band;
mod labels;
mod model;
mod protocol;

use std::process::exit;

use framing::{log_record, LogLevel, Writer};
use model::{Geometry, Shape};
use protocol::{labels_record, parse_request};
use qnn::TimeLog;

fn log(writer: &Writer, level: LogLevel, message: &str) {
    let _ = writer.write_record(&log_record(level, message));
}

/// A failure before stdout carries records goes to stderr.
fn exit_early(message: &str, status: i32) -> ! {
    eprintln!("qnn_segment: {message}");
    exit(status)
}

fn main() {
    let command_line: Vec<String> = std::env::args().collect();
    if command_line.len() != 2 {
        exit_early("usage: qnn_segment <context.bin>", 2);
    }
    let context_path = &command_line[1];

    // Before any QNN call: its libraries may log onto stdout.
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(error) => exit_early(&format!("stdout: {error}"), 1),
    };
    writer.log_panics();

    if let Err(message) = run(context_path, &writer) {
        log(&writer, LogLevel::Error, &message);
        exit(1);
    }
}

fn shapes(tensors: &[qnn::Tensor]) -> Vec<Shape<'_>> {
    tensors
        .iter()
        .map(|tensor| Shape {
            name: &tensor.name,
            dimensions: &tensor.dimensions,
            unsigned_8bit: tensor.unsigned_8bit,
            scale: tensor.scale_offset.map(|(scale, _)| scale),
        })
        .collect()
}

fn run(context_path: &str, writer: &Writer) -> Result<(), String> {
    let binary = std::fs::read(context_path).map_err(|e| format!("{context_path}: {e}"))?;
    let mut model = qnn::Model::open(&binary)?;
    drop(binary);

    let Geometry {
        input_width,
        input_height,
        output_width,
        output_height,
        classes,
    } = model::geometry(&shapes(&model.inputs), &shapes(&model.outputs))?;

    log(
        writer,
        LogLevel::Info,
        &format!(
            "ready: {context_path}, input {} {:?} quantisation {:?}, output {} {:?} \
             quantisation {:?}",
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

    while let Ok(Some(record)) = framing::read_record(&mut stdin) {
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
                );
                match model.execute(&mut [input.as_mut_slice()], &mut [scores.as_mut_slice()]) {
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
                        labels::argmax_into(&scores, classes, &mut labels);
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
    }
    Ok(())
}
