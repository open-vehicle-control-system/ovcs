//! The segmentation network: a HEF whose argmax is in-graph, so a request's band is resized to
//! its input and the class ids it gives, one a pixel, are kept as one a cell. A request's image
//! comes as its pixels or as a JPEG, which the network decodes.

use std::sync::Arc;

use framing::{LogLevel, Writer};
use segmentation::band::resize_band;
use segmentation::protocol::{labels_record, parse_jpeg_request, parse_request, Request};

use crate::grid::cell_labels;
use crate::hailo::{io, Device, Network, HAILO_FORMAT_TYPE_UINT8};
use crate::jpeg::RgbDecoder;
use crate::outcome::{reply_for, FrameOutcome, Reply};
use crate::{log, Answer};

/// Threads the band's resize splits its rows across.
const RESIZE_THREADS: usize = 2;

pub struct Segment {
    network: Network,
    cell_pixels: usize,
    decoder: RgbDecoder,
    decoded: Vec<u8>,
}

impl Segment {
    /// `cell_pixels`, the side of the cells the labels are kept at, in the model's pixels.
    pub fn open(
        device: &Arc<Device>,
        hef_path: &str,
        cell_pixels: usize,
    ) -> Result<Segment, String> {
        let network = Network::open(device, hef_path, HAILO_FORMAT_TYPE_UINT8)?;
        let (input, output) = (network.input, network.output_shape());
        if input.features != 3 {
            return Err(format!(
                "{hef_path}: expected a 3-channel input, got {}",
                input.features
            ));
        }
        if output.features != 1 || output.width != input.width || output.height != input.height {
            return Err(format!(
                "{hef_path}: expected one class id a pixel of its {}x{} input, its output is {}x{}x{}",
                input.width, input.height, output.width, output.height, output.features
            ));
        }
        Ok(Segment {
            cell_pixels,
            decoder: RgbDecoder::new()?,
            decoded: Vec::new(),
            network,
        })
    }

    pub fn description(&self) -> String {
        let input = self.network.input;
        format!(
            "{}x{}, labels in {}x{} cells, {}",
            input.width,
            input.height,
            self.cell_pixels,
            self.cell_pixels,
            io(&self.network)
        )
    }

    /// The reply to the segment request `record`, one whatever happens to it.
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
                    band_top: request.band_top,
                    band_height: request.band_height,
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
                Answer::Reply(labels_record(request.sequence, 0, 0, &[], None))
            }
        };
        self.decoded = decoded;
        answer
    }

    fn answer_request(&mut self, request: &Request, writer: &Writer) -> Answer {
        let input = self.network.input;
        let mut inference_time = None;
        let outcome = match request.check() {
            Err(message) => {
                log(writer, LogLevel::Warning, &message);
                FrameOutcome::Rejected
            }
            Ok(()) => {
                let top = usize::from(request.band_top);
                resize_band(
                    request.pixels,
                    usize::from(request.width),
                    top..top + usize::from(request.band_height),
                    self.network.input_mut(),
                    input.width,
                    input.height,
                    RESIZE_THREADS,
                );
                match self.network.infer() {
                    Ok(elapsed) => {
                        inference_time = Some(elapsed.as_micros() as u64);
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
        let empty = labels_record(request.sequence, 0, 0, &[], None);
        match reply_for(outcome) {
            Reply::Empty => return Answer::Reply(empty),
            Reply::EmptyThenExit => {
                log(
                    writer,
                    LogLevel::Warning,
                    "segmentation vstreams may hold a frame in flight; exiting for a restart",
                );
                return Answer::ReplyThenExit(empty);
            }
            Reply::Result => {}
        }

        let (columns, rows, cells) = cell_labels(
            self.network.output(),
            input.width,
            input.height,
            self.cell_pixels,
        );
        Answer::Reply(labels_record(
            request.sequence,
            columns as u16,
            rows as u16,
            &cells,
            inference_time,
        ))
    }
}
