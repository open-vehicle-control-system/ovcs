//! The detection network: a HEF whose NMS is in-graph, so a request's pixels are letterboxed
//! in and its boxes read back out, in the request's pixel coordinates. A request's image comes
//! as its pixels or as a JPEG, which the network decodes.

use std::sync::Arc;

use detection::letterbox::{letterbox_for, letterbox_into};
use detection::nms;
use detection::protocol::{
    detections_record, inference_micros, parse_jpeg_request, parse_request, Request,
};
use framing::{LogLevel, Writer};

use crate::hailo::{io, Device, Network, HAILO_FORMAT_TYPE_FLOAT32};
use crate::jpeg::SharedDecoder;
use crate::outcome::{reply_for, FrameOutcome, Reply};
use crate::Answer;

/// Threads the letterbox splits its rows across.
const LETTERBOX_THREADS: usize = 1;

pub struct Detect {
    network: Network,
    model_size: i32,
    class_count: usize,
    score_threshold: f32,
    jpegs: Arc<SharedDecoder>,
}

impl Detect {
    pub fn open(
        device: &Arc<Device>,
        hef_path: &str,
        score_threshold: f32,
        jpegs: &Arc<SharedDecoder>,
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
        Ok(Detect {
            class_count: network
                .nms_classes()
                .map_err(|message| format!("{hef_path}: {message}"))?,
            model_size: model_size as i32,
            score_threshold,
            jpegs: Arc::clone(jpegs),
            network,
        })
    }

    pub fn description(&self) -> String {
        format!(
            "{size}x{size}, {} classes, threshold {}, {}",
            self.class_count,
            self.score_threshold,
            io(&self.network),
            size = self.model_size
        )
    }

    /// The reply to the detect request `record`, one whatever happens to it.
    pub fn answer(&mut self, record: &[u8], writer: &Writer) -> Answer {
        if let Some(request) = parse_request(record) {
            return self.answer_request(&request, writer);
        }
        let Some(request) = parse_jpeg_request(record) else {
            return Answer::Nothing;
        };
        let decoded = match self.jpegs.decode(request.jpeg) {
            Ok(decoded) => decoded,
            Err(message) => {
                writer.log(
                    LogLevel::Warning,
                    &format!("frame {}: {message}", request.sequence),
                );
                return Answer::Reply(detections_record(request.sequence, &[], None));
            }
        };
        self.answer_request(
            &Request {
                sequence: request.sequence,
                width: decoded.width,
                height: decoded.height,
                channels: 3,
                pixels: &decoded.pixels,
            },
            writer,
        )
    }

    fn answer_request(&mut self, request: &Request, writer: &Writer) -> Answer {
        let (width, height) = (i32::from(request.width), i32::from(request.height));
        let letterbox = letterbox_for(width, height, self.model_size);
        let mut inference_time = None;
        let outcome = match request.check() {
            Err(message) => {
                writer.log(LogLevel::Warning, &message);
                FrameOutcome::Rejected
            }
            Ok(frame) => {
                letterbox_into(
                    &frame,
                    self.network.input_mut(),
                    &letterbox,
                    LETTERBOX_THREADS,
                );
                match self.network.infer() {
                    Ok(elapsed) => {
                        inference_time = Some(inference_micros(elapsed.as_micros()));
                        FrameOutcome::Inferred
                    }
                    Err(failure) => {
                        writer.log(LogLevel::Error, &failure.message);
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
                writer.log(
                    LogLevel::Warning,
                    "detection vstreams may hold a frame in flight; exiting for a restart",
                );
                return Answer::ReplyThenExit(empty);
            }
            Reply::Result => {}
        }

        let output = self.network.output();
        // SAFETY: the output buffer is page-aligned, so f32-aligned, and HailoRT wrote f32s.
        let output = unsafe {
            std::slice::from_raw_parts(
                output.as_ptr().cast::<f32>(),
                output.len() / std::mem::size_of::<f32>(),
            )
        };
        let detections =
            nms::decode_nms_by_class(output, self.class_count, &letterbox, self.score_threshold);
        Answer::Reply(detections_record(
            request.sequence,
            &detections,
            inference_time,
        ))
    }
}
