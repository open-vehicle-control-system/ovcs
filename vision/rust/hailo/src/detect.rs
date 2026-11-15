//! The detection network: a HEF whose NMS is in-graph, so a request's pixels are letterboxed
//! in and its boxes read back out, in the request's pixel coordinates. A request's image comes
//! as its pixels or as a JPEG, which the network decodes.

use std::sync::Arc;

use detection::letterbox::{letterbox_for, letterbox_into, Frame};
use detection::nms;
use detection::protocol::{
    detections_record, inference_micros, parse_jpeg_request, parse_request, Request,
};
use framing::{LogLevel, Writer};

use crate::hailo::{io, Device, Network, HAILO_FORMAT_TYPE_FLOAT32};
use crate::jpeg::RgbDecoder;
use crate::outcome::{reply_for, FrameOutcome, Reply};
use crate::{log, Answer};

/// Threads the letterbox splits its rows across.
const LETTERBOX_THREADS: usize = 1;

pub struct Detect {
    network: Network,
    model_size: i32,
    class_count: usize,
    score_threshold: f32,
    decoder: RgbDecoder,
    decoded: Vec<u8>,
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
        Ok(Detect {
            class_count: network.nms_classes(),
            model_size: model_size as i32,
            score_threshold,
            decoder: RgbDecoder::new()?,
            decoded: Vec::new(),
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
        let mut decoded = std::mem::take(&mut self.decoded);
        let answer = match self.decoder.decode(request.jpeg, &mut decoded) {
            Ok((width, height)) => self.answer_request(
                &Request {
                    sequence: request.sequence,
                    width,
                    height,
                    channels: 3,
                    pixels: &decoded,
                },
                writer,
            ),
            Err(message) => {
                log(
                    writer,
                    LogLevel::Warning,
                    &format!("frame {}: {message}", request.sequence),
                );
                Answer::Reply(detections_record(request.sequence, &[], None))
            }
        };
        self.decoded = decoded;
        answer
    }

    fn answer_request(&mut self, request: &Request, writer: &Writer) -> Answer {
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
                    self.network.input_mut(),
                    self.model_size,
                    &letterbox,
                    LETTERBOX_THREADS,
                );
                match self.network.infer() {
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

        let output = self.network.output();
        // SAFETY: the output buffer is page-aligned, so f32-aligned, and HailoRT wrote f32s.
        let output = unsafe {
            std::slice::from_raw_parts(
                output.as_ptr().cast::<f32>(),
                output.len() / std::mem::size_of::<f32>(),
            )
        };
        let detections = nms::decode_nms_by_class(
            output,
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
