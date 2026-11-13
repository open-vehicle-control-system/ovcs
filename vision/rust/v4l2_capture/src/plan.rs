//! A single camera's outputs planned once from their specifications: what
//! makes each one's image of a frame, in the outputs' order.

use framing::{output_frame_header, output_jpeg_header};

use crate::arguments::{Format, OutputSpec, Source};
use crate::bands::{Images, Measures};
use crate::bayer::RawFrame;
use crate::jpeg::JpegOutput;
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
}

struct OutputPlan {
    spec: OutputSpec,
    role: Role,
}

/// Each output's role, in the outputs' order.
pub struct Plan {
    outputs: Vec<OutputPlan>,
    averager: Averager,
}

impl Plan {
    /// The plan of `outputs` from a `model` sensor. Each `from:` output names
    /// an earlier one, as the command line guarantees: the image a role reads
    /// is made before it, and the one a processor averages into comes after
    /// its own.
    pub fn new(outputs: &[OutputSpec], model: SensorModel) -> Plan {
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
        let mut jpegs = 0;
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
                (None, Source::Cpu(_), _) => unreachable!("a processor makes it"),
            };
            planned.push(OutputPlan { spec, role });
        }
        Plan {
            outputs: planned,
            averager: Averager::default(),
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

    /// Each output's place among a frame's JPEGs, for those sent as one.
    pub fn jpeg_slots(&self) -> Vec<Option<usize>> {
        (self.outputs.iter())
            .map(|output| match output.role {
                Role::Jpeg { slot, .. } => Some(slot),
                _ => None,
            })
            .collect()
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

    /// The header of each output sent, with its index, for the frame started
    /// at `start_ns`.
    pub fn headers(&self, start_ns: i64) -> Vec<(usize, [u8; 14])> {
        (self.outputs.iter().enumerate())
            .filter(|(_, output)| output.spec.send)
            .map(|(index, output)| {
                let (width, height) = (output.spec.width as u16, output.spec.height as u16);
                let header = match output.spec.format {
                    Format::Rgb => output_frame_header,
                    Format::Jpeg { .. } => output_jpeg_header,
                };
                (index, header(index as u8, width, height, start_ns))
            })
            .collect()
    }
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
    fn roles(outputs: &[OutputSpec]) -> Vec<String> {
        let plan = Plan::new(outputs, SensorModel::Imx477);
        (plan.outputs.iter())
            .map(|output| match output.role {
                Role::Processed { averaged_into, .. } => format!("processed {averaged_into:?}"),
                Role::AveragedAlong => "averaged along".to_string(),
                Role::ScaledAfter { from, block } => format!("scaled {from} {block:?}"),
                Role::Jpeg { from, slot } => format!("jpeg {from} {slot}"),
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
            roles(&outputs),
            [
                "processed Some(2)",
                "jpeg 0 0",
                "averaged along",
                "scaled 0 (2, 2)",
                "scaled 2 (2, 1)",
                "jpeg 2 1",
            ]
        );
        let plan = Plan::new(&outputs, SensorModel::Imx477);
        assert_eq!(
            plan.jpeg_slots(),
            [None, Some(0), None, None, None, Some(1)]
        );
        assert_eq!(plan.jpeg_outputs().len(), 2);
        assert!(plan.scales());
        assert_eq!(plan.default_threads(), 3);
    }

    #[test]
    fn only_the_outputs_sent_have_a_header() {
        let unsent = OutputSpec {
            send: false,
            ..spec(Source::Cpu(Output::Half), (12, 23), Format::Rgb)
        };
        let outputs = [unsent, spec(Source::From(0), (6, 23), Format::Rgb)];
        let plan = Plan::new(&outputs, SensorModel::Imx477);
        let headers = plan.headers(5);
        assert_eq!(headers.len(), 1);
        assert_eq!(headers[0], (1, output_frame_header(1, 6, 23, 5)));
        assert_eq!(plan.default_threads(), 1);
    }
}
