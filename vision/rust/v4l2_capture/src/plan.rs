//! A single camera's outputs planned once from their specifications: what
//! makes each one's image of a frame, in the outputs' order.

use framing::{output_frame_header, output_jpeg_header};

use crate::arguments::{Format, OutputSpec, Source};
use crate::bands::{Images, Measures};
use crate::bayer::RawFrame;
use crate::jpeg::JpegOutput;
use crate::nv12::{self, Nv12Layout};
use crate::processor::{Cpu, Development, Processor};
use crate::scale::Averager;
use crate::sensor::SensorModel;

/// What makes an output's image of a frame.
enum Role {
    /// A processor converts the raw frame into it and, with `averaged_into`,
    /// into the 2x2 average of it that this later output is.
    Processed {
        processor: Box<dyn Processor>,
        averaged_into: Option<usize>,
    },
    /// The processor of the output it is made from averages it as it converts,
    /// while the rows are in cache.
    AveragedAlong,
    /// Averaged after the processors from the earlier output `from`, each
    /// pixel a `block` of its pixels.
    ScaledAfter { from: usize, block: (usize, usize) },
    /// Encoded from the earlier output `from` on the encoder thread, the
    /// `slot`th of a frame's JPEGs; it has no image.
    Jpeg { from: usize, slot: usize },
    /// Converted to NV12 laid out as `layout` after the outputs scaled, from
    /// the earlier output `from`, averaged first in blocks of `block` pixels,
    /// and encoded by the `slot`th of a frame's video encoders.
    H264 {
        from: usize,
        block: (usize, usize),
        slot: usize,
        layout: Nv12Layout,
    },
}

struct OutputPlan {
    spec: OutputSpec,
    role: Role,
}

/// Each output's role, in the outputs' order.
pub struct Plan {
    outputs: Vec<OutputPlan>,
    averager: Averager,
    /// An H.264 output's source averaged, when it is a fraction of it.
    averaged: Vec<u8>,
}

impl Plan {
    /// The plan of `outputs` from a `model` sensor. Each `from:` output names
    /// an earlier one, as the command line guarantees: the image a role reads
    /// is made before it, and the one a processor averages into comes after
    /// its own. `layouts` are the NV12 layouts of the H.264 outputs'
    /// encoders, in the outputs' order.
    pub fn new(outputs: &[OutputSpec], model: SensorModel, layouts: &[Nv12Layout]) -> Plan {
        let mut roles: Vec<Option<Role>> = outputs.iter().map(|_| None).collect();
        for (index, spec) in outputs.iter().enumerate() {
            let Source::Cpu(output) = spec.source else {
                continue;
            };
            let processor = Box::new(Cpu::new(model, output)) as Box<dyn Processor>;
            let averaged_into = (processor.averages_2x2())
                .then(|| {
                    outputs.iter().position(|later| {
                        later.source == Source::From(index)
                            && later.format == Format::Rgb
                            && later.block(spec) == (2, 2)
                    })
                })
                .flatten();
            if let Some(averaged) = averaged_into {
                roles[averaged] = Some(Role::AveragedAlong);
            }
            roles[index] = Some(Role::Processed {
                processor,
                averaged_into,
            });
        }
        let (mut jpegs, mut videos) = (0, 0);
        let mut planned = Vec::with_capacity(outputs.len());
        for (&spec, role) in outputs.iter().zip(roles) {
            let role = match (role, spec.source, spec.format) {
                (Some(role), _, _) => role,
                (None, Source::From(from), Format::Rgb) => Role::ScaledAfter {
                    from,
                    block: spec.block(&outputs[from]),
                },
                (None, Source::From(from), Format::Jpeg { .. }) => {
                    jpegs += 1;
                    Role::Jpeg {
                        from,
                        slot: jpegs - 1,
                    }
                }
                (None, Source::From(from), Format::H264 { .. }) => {
                    videos += 1;
                    Role::H264 {
                        from,
                        block: spec.block(&outputs[from]),
                        slot: videos - 1,
                        layout: layouts[videos - 1],
                    }
                }
                (None, Source::Cpu(_), _) => unreachable!("a processor makes it"),
            };
            planned.push(OutputPlan { spec, role });
        }
        Plan {
            outputs: planned,
            averager: Averager::default(),
            averaged: Vec::new(),
        }
    }

    /// How many outputs there are.
    pub fn output_count(&self) -> usize {
        self.outputs.len()
    }

    /// The threads converting each frame unless the `threads` setting says
    /// otherwise: the most any processed output asks for.
    pub fn default_threads(&self) -> usize {
        (self.outputs.iter())
            .filter_map(|output| match output.spec.source {
                Source::Cpu(output) => Some(output.threads()),
                Source::From(_) => None,
            })
            .max()
            .unwrap_or(1)
    }

    /// How many of a frame's outputs are sent as JPEGs.
    pub fn jpeg_count(&self) -> usize {
        (self.outputs.iter())
            .filter(|output| matches!(output.role, Role::Jpeg { .. }))
            .count()
    }

    /// The outputs sent as JPEGs, in the order of their slots.
    pub fn jpeg_outputs(&self) -> Vec<JpegOutput> {
        (self.outputs.iter())
            .filter_map(|output| match (&output.role, output.spec.format) {
                (&Role::Jpeg { from, .. }, Format::Jpeg { quality }) => Some(JpegOutput::new(
                    from,
                    &self.outputs[from].spec,
                    &output.spec,
                    quality,
                )),
                _ => None,
            })
            .collect()
    }

    /// Converts `raw` into the image of each processed output, and of each one
    /// averaged along, as `development` says, whose measures the first
    /// processor takes.
    pub fn develop(
        &mut self,
        raw: &RawFrame,
        development: &Development,
        images: &mut [Vec<u8>],
    ) -> Measures {
        let mut measured = None;
        for (index, output) in self.outputs.iter_mut().enumerate() {
            let Role::Processed {
                processor,
                averaged_into,
            } = &mut output.role
            else {
                continue;
            };
            let development = Development {
                settings: development.settings,
                gains: development.gains,
                tone: development.tone,
                channel_means: development.channel_means && measured.is_none(),
                green_mean: development.green_mean && measured.is_none(),
                threads: development.threads,
            };
            let (made, later) = images.split_at_mut(index + 1);
            let target = Images {
                rgb: &mut made[index],
                averaged: averaged_into.map(|output| &mut later[output - index - 1]),
            };
            let measures = processor.develop(raw, &development, target);
            measured.get_or_insert(measures);
        }
        measured.expect("an output made by a processor")
    }

    /// Whether `scale` has an output to make.
    pub fn scales(&self) -> bool {
        (self.outputs.iter()).any(|output| matches!(output.role, Role::ScaledAfter { .. }))
    }

    /// Makes each output scaled after the processors, in order, into its
    /// image of `images`, on `threads` threads.
    pub fn scale(&mut self, threads: usize, images: &mut [Vec<u8>]) {
        for (index, output) in self.outputs.iter().enumerate() {
            let Role::ScaledAfter { from, block } = output.role else {
                continue;
            };
            let (made, rest) = images.split_at_mut(index);
            let source_width = self.outputs[from].spec.width as usize;
            (self.averager).average_blocks(&made[from], source_width, block, threads, &mut rest[0]);
        }
    }

    /// The indices of the outputs sent as H.264, in the order of their slots.
    pub fn h264_outputs(&self) -> Vec<usize> {
        (self.outputs.iter().enumerate())
            .filter(|(_, output)| matches!(output.role, Role::H264 { .. }))
            .map(|(index, _)| index)
            .collect()
    }

    /// Converts the source of each output sent as H.264 to its NV12 image
    /// of `images`, on `threads` threads.
    pub fn convert_to_nv12(&mut self, threads: usize, images: &mut [Vec<u8>]) {
        for (index, output) in self.outputs.iter().enumerate() {
            let Role::H264 {
                from,
                block,
                layout,
                ..
            } = output.role
            else {
                continue;
            };
            let (made, rest) = images.split_at_mut(index);
            let source = if block == (1, 1) {
                &made[from]
            } else {
                let source_width = self.outputs[from].spec.width as usize;
                let averaged = &mut self.averaged;
                (self.averager).average_blocks(&made[from], source_width, block, threads, averaged);
                &self.averaged
            };
            rest[0].resize(layout.size, 0);
            nv12::convert(source, &layout, threads, &mut rest[0]);
        }
    }

    /// What the writer writes of each output sent, with its index, for the
    /// frame started at `start_ns`.
    pub fn sent(&self, start_ns: i64) -> Vec<(usize, Sent)> {
        (self.outputs.iter().enumerate())
            .filter(|(_, output)| output.spec.send)
            .map(|(index, output)| {
                let (width, height) = (output.spec.width as u16, output.spec.height as u16);
                let sent = match output.role {
                    Role::Jpeg { slot, .. } => Sent::Jpeg {
                        header: output_jpeg_header(index as u8, width, height, start_ns),
                        slot,
                    },
                    Role::H264 { slot, .. } => Sent::H264 {
                        slot,
                        width,
                        height,
                    },
                    _ => Sent::Image(output_frame_header(index as u8, width, height, start_ns)),
                };
                (index, sent)
            })
            .collect()
    }
}

/// What the writer writes of an output sent, in a frame's records.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Sent {
    /// Its image, after this header.
    Image([u8; 14]),
    /// The `slot`th of the frame's JPEGs, after this header.
    Jpeg { header: [u8; 14], slot: usize },
    /// What the `slot`th of the frame's video encoders gives, a record
    /// headed by the encoded frame's capture time and key frame flag.
    H264 {
        slot: usize,
        width: u16,
        height: u16,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arguments::Output;

    fn spec(source: Source, (width, height): (u32, u32), format: Format) -> OutputSpec {
        OutputSpec {
            source,
            width,
            height,
            format,
            send: true,
        }
    }

    // What makes each output, by name.
    fn roles(outputs: &[OutputSpec], layouts: &[Nv12Layout]) -> Vec<String> {
        let plan = Plan::new(outputs, SensorModel::Imx477, layouts);
        (plan.outputs.iter())
            .map(|output| match output.role {
                Role::Processed { averaged_into, .. } => format!("processed {averaged_into:?}"),
                Role::AveragedAlong => "averaged along".to_string(),
                Role::ScaledAfter { from, block } => format!("scaled {from} {block:?}"),
                Role::Jpeg { from, slot } => format!("jpeg {from} {slot}"),
                Role::H264 {
                    from, block, slot, ..
                } => format!("h264 {from} {block:?} {slot}"),
            })
            .collect()
    }

    #[test]
    fn a_processor_averages_the_first_half_size_rgb_output_made_from_its_own() {
        let outputs = [
            spec(Source::Cpu(Output::Full), (24, 46), Format::Rgb),
            spec(Source::From(0), (24, 46), Format::Jpeg { quality: 80 }),
            spec(Source::From(0), (12, 23), Format::Rgb),
            spec(Source::From(0), (12, 23), Format::Rgb),
            spec(Source::From(2), (6, 23), Format::Rgb),
            spec(Source::From(2), (12, 23), Format::Jpeg { quality: 90 }),
        ];
        assert_eq!(
            roles(&outputs, &[]),
            [
                "processed Some(2)",
                "jpeg 0 0",
                "averaged along",
                "scaled 0 (2, 2)",
                "scaled 2 (2, 1)",
                "jpeg 2 1",
            ]
        );
        let plan = Plan::new(&outputs, SensorModel::Imx477, &[]);
        let jpegs: Vec<(usize, usize)> = (plan.sent(5).into_iter())
            .filter_map(|(index, sent)| match sent {
                Sent::Jpeg { header, slot } => {
                    assert_eq!(header[..2], [8, index as u8]);
                    Some((index, slot))
                }
                Sent::Image(_) | Sent::H264 { .. } => None,
            })
            .collect();
        assert_eq!(jpegs, [(1, 0), (5, 1)]);
        assert_eq!(plan.jpeg_count(), 2);
        assert_eq!(plan.jpeg_outputs().len(), 2);
        assert!(plan.scales());
        assert_eq!(plan.default_threads(), 3);
    }

    #[test]
    fn each_h264_output_is_converted_to_the_nv12_layout_of_its_encoder() {
        let h264 = Format::H264 {
            bitrate_kbps: 4_000,
            keyframe_interval: 30,
        };
        let outputs = [
            spec(Source::Cpu(Output::Full), (24, 46), Format::Rgb),
            spec(Source::From(0), (12, 23), Format::Rgb),
            spec(Source::From(0), (24, 46), h264),
            spec(Source::From(0), (12, 46), h264),
        ];
        let layout = |width, height, stride, luma_rows| Nv12Layout {
            width,
            height,
            stride,
            luma_rows,
            size: stride * luma_rows * 3 / 2,
        };
        let layouts = [layout(24, 46, 32, 64), layout(12, 46, 16, 64)];
        let mut plan = Plan::new(&outputs, SensorModel::Imx477, &layouts);
        assert_eq!(
            roles(&outputs, &layouts)[2..],
            ["h264 0 (1, 1) 0", "h264 0 (2, 1) 1"]
        );
        assert_eq!(plan.h264_outputs(), [2, 3]);
        assert_eq!(
            plan.sent(5)[2..],
            [
                (
                    2,
                    Sent::H264 {
                        slot: 0,
                        width: 24,
                        height: 46
                    }
                ),
                (
                    3,
                    Sent::H264 {
                        slot: 1,
                        width: 12,
                        height: 46
                    }
                )
            ]
        );

        let rgb: Vec<u8> = (0..24 * 46 * 3).map(|byte| (byte * 7) as u8).collect();
        let mut images = vec![rgb.clone(), Vec::new(), Vec::new(), Vec::new()];
        plan.convert_to_nv12(2, &mut images);
        let mut halved = Vec::new();
        Averager::default().average_blocks(&rgb, 24, (2, 1), 1, &mut halved);
        for (image, source, layout) in [(2, &rgb, layouts[0]), (3, &halved, layouts[1])] {
            let mut expected = vec![0; layout.size];
            nv12::convert(source, &layout, 1, &mut expected);
            assert!(images[image] == expected, "output {image}");
        }
    }

    #[test]
    fn only_the_outputs_sent_are_written() {
        let unsent = OutputSpec {
            send: false,
            ..spec(Source::Cpu(Output::Half), (12, 23), Format::Rgb)
        };
        let outputs = [unsent, spec(Source::From(0), (6, 23), Format::Rgb)];
        let plan = Plan::new(&outputs, SensorModel::Imx477, &[]);
        assert_eq!(
            plan.sent(5),
            [(1, Sent::Image(output_frame_header(1, 6, 23, 5)))]
        );
        assert_eq!(plan.default_threads(), 1);
    }
}
