//! The detection network: a HEF whose NMS is in-graph, so a request's pixels are letterboxed
//! in and its boxes read back out, in the request's pixel coordinates.

use std::sync::Arc;

use detection::letterbox::{letterbox_for, letterbox_into, Frame};
use detection::nms;
use detection::protocol::{detections_record, inference_micros, parse_request};
use framing::{LogLevel, Writer};

use crate::hailo::{Device, Network, HAILO_FORMAT_TYPE_FLOAT32};
use crate::outcome::{reply_for, FrameOutcome, Reply};
use crate::{log, Answer};

/// Threads the letterbox splits its rows across.
const LETTERBOX_THREADS: usize = 1;

pub struct Detect {
    network: Network,
    model_size: i32,
    class_count: usize,
    score_threshold: f32,
    model_input: Vec<u8>,
    output: Vec<f32>,
}

impl Detect {
    pub fn open(
        device: &Arc<Device>,
        hef_path: &str,
        score_threshold: f32,
    ) -> Result<Detect, String> {
        let network = Network::open(device, hef_path, HAILO_FORMAT_TYPE_FLOAT32)?;
        let input = network.input;
        if input.height != input.width || input.features != 3 {
            return Err(format!(
                "{hef_path}: expected a square 3-channel input, got {}x{}x{}",
                input.width, input.height, input.features
            ));
        }
        let model_size = input.width;
        let output_floats = network.output_bytes.div_ceil(std::mem::size_of::<f32>());
        Ok(Detect {
            class_count: network.nms_classes(),
            model_size: model_size as i32,
            score_threshold,
            model_input: vec![0u8; model_size * model_size * 3],
            output: vec![0f32; output_floats],
            network,
        })
    }

    pub fn description(&self) -> String {
        format!(
            "{size}x{size}, {} classes, threshold {}",
            self.class_count,
            self.score_threshold,
            size = self.model_size
        )
    }

    /// The reply to the detect request `record`, one whatever happens to it.
    pub fn answer(&mut self, record: &[u8], writer: &Writer) -> Answer {
        let Some(request) = parse_request(record) else {
            return Answer::Nothing;
        };
        let (width, height) = (i32::from(request.width), i32::from(request.height));
        let letterbox = letterbox_for(width, height, self.model_size);
        let mut inference_time = None;
        let outcome = match request.check() {
            Err(message) => {
                log(writer, LogLevel::Warning, &message);
                FrameOutcome::Rejected
            }
            Ok(()) => {
                letterbox_into(
                    &Frame {
                        pixels: request.pixels,
                        width,
                        height,
                        channels: request.channels,
                    },
                    &mut self.model_input,
                    self.model_size,
                    &letterbox,
                    LETTERBOX_THREADS,
                );
                // SAFETY: the f32 buffer viewed as its bytes, for HailoRT to write into.
                let output_bytes = unsafe {
                    std::slice::from_raw_parts_mut(
                        self.output.as_mut_ptr().cast::<u8>(),
                        std::mem::size_of_val(self.output.as_slice()),
                    )
                };
                match self.network.infer(&self.model_input, output_bytes) {
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

        // The Elixir side holds per-sequence state until it gets an answer.
        let empty = detections_record(request.sequence, &[], None);
        match reply_for(outcome) {
            Reply::Empty => return Answer::Reply(empty),
            Reply::EmptyThenExit => {
                log(
                    writer,
                    LogLevel::Warning,
                    "detection vstreams may hold a frame in flight; exiting for a restart",
                );
                return Answer::ReplyThenExit(empty);
            }
            Reply::Result => {}
        }

        let detections = nms::decode_nms_by_class(
            &self.output[..self.network.output_bytes / std::mem::size_of::<f32>()],
            self.class_count,
            width,
            height,
            &letterbox,
            self.model_size,
            self.score_threshold,
        );
        Answer::Reply(detections_record(
            request.sequence,
            &detections,
            inference_time,
        ))
    }
}
