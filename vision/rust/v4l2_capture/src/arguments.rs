//! Command line of `v4l2_capture`.

use std::str::FromStr;

use crate::sensor::SensorModel;
use crate::settings::{ColourSettings, Settings};

/// What to capture: the stereo pair, or a single colour camera.
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    Pair(Arguments),
    Single(SingleArguments),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Arguments {
    /// Output size; the sensor runs at twice this in each axis.
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub left: Nodes,
    pub right: Nodes,
    pub settings: Settings,
}

/// The command line of a single colour camera.
#[derive(Clone, Debug, PartialEq)]
pub struct SingleArguments {
    /// The capture size.
    pub sensor_width: u32,
    pub sensor_height: u32,
    pub fps: u32,
    pub camera: Nodes,
    /// Each output, in the order of their indices; one of the capture's
    /// size by default.
    pub outputs: Vec<OutputSpec>,
    pub settings: ColourSettings,
}

/// One of a single camera's outputs: the size of its frames, what makes
/// them and how they are sent.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutputSpec {
    pub source: Source,
    pub width: u32,
    pub height: u32,
    pub format: Format,
    /// Whether its records are written; one not sent is made only for the
    /// outputs made from it.
    pub send: bool,
}

/// How an output's frames are sent.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Format {
    /// 8-bit red, green and blue pixels.
    Rgb,
    /// A JPEG of those pixels at `quality`, 1 to 100.
    Jpeg { quality: u8 },
}

/// What makes an output.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Source {
    /// The software conversion of the sensor's frame (`processor::Cpu`).
    Cpu(Output),
    /// Each pixel the average of a block of the output of this index,
    /// an earlier one (`scale`).
    From(usize),
}

impl OutputSpec {
    /// The block of `source`'s pixels each of this output's averages.
    pub fn block(&self, source: &OutputSpec) -> (usize, usize) {
        (
            (source.width / self.width) as usize,
            (source.height / self.height) as usize,
        )
    }
}

/// The most outputs a single camera has: a record's output index is a byte.
const MAX_OUTPUTS: usize = 256;

/// The size of the RGB frames the processor makes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Output {
    /// The capture size, every sample a pixel.
    Full,
    /// Half the capture size in each axis, every RGGB cell a pixel.
    Half,
}

impl Output {
    /// The width and height of the frames from a `sensor_width` by
    /// `sensor_height` capture.
    pub fn size(self, sensor_width: u32, sensor_height: u32) -> (u32, u32) {
        match self {
            Output::Full => (sensor_width, sensor_height),
            Output::Half => (sensor_width / 2, sensor_height / 2),
        }
    }

    /// The threads converting each frame unless the `threads` setting says
    /// otherwise: a frame of the capture size takes several cores to keep
    /// up with the sensor.
    pub fn threads(self) -> usize {
        match self {
            Output::Full => 3,
            Output::Half => 1,
        }
    }
}

/// The V4L2 names of one camera's capture node and sensor subdevice.
#[derive(Clone, Debug, PartialEq)]
pub struct Nodes {
    pub video: String,
    pub sensor: String,
}

const SINGLE_FLAGS: [&str; 4] = ["--video", "--sensor", "--sensor-width", "--sensor-height"];
const PAIR_FLAGS: [&str; 6] = [
    "--width",
    "--height",
    "--left-video",
    "--left-sensor",
    "--right-video",
    "--right-sensor",
];

/// Parses the arguments after the program name: a single camera's when they
/// name its nodes (`--video`, `--sensor`, see `parse_single`), the pair's
/// otherwise (see `parse`). The error is the message to log.
pub fn parse_command(arguments: &[String]) -> Result<Command, String> {
    let flags: Vec<&str> = arguments.iter().step_by(2).map(String::as_str).collect();
    if !flags.iter().any(|flag| SINGLE_FLAGS.contains(flag)) {
        return parse(arguments).map(Command::Pair);
    }
    match flags.iter().find(|flag| PAIR_FLAGS.contains(flag)) {
        Some(flag) => Err(format!(
            "a single camera (--video, --sensor) takes no {flag}"
        )),
        None => parse_single(arguments).map(Command::Single),
    }
}

/// Parses a single camera's arguments: its capture size and rate, its nodes,
/// its outputs, then any setting as `--name value`, with dashes for
/// underscores. Each `--output`, in the order of their indices, is
/// `cpu:<width>x<height>`, made by the software conversion at the capture's
/// size or half of it, or `from:<index>:<width>x<height>`, scaled from an
/// earlier output to a whole fraction of its size, sent as a JPEG with
/// `:jpeg:<quality>` after it; an RGB one followed by `:unsent` is made
/// but not sent, for the outputs made from it. Without, one output of the
/// capture's size. The error is the message to log.
pub fn parse_single(arguments: &[String]) -> Result<SingleArguments, String> {
    let (mut sensor_width, mut sensor_height, mut fps) = (None, None, None);
    let (mut video, mut sensor) = (None, None);
    let mut outputs = Vec::new();
    // The settings start from the sensor's, wherever `--sensor` comes.
    let named = (arguments.chunks_exact(2)).find(|pair| pair[0] == "--sensor");
    let model = SensorModel::for_sensor(named.map_or("", |pair| pair[1].as_str()));
    let mut settings = ColourSettings::for_sensor(model);
    let mut rest = arguments.iter();
    while let Some(flag) = rest.next() {
        let value = rest
            .next()
            .ok_or_else(|| format!("{flag}: missing value"))?;
        match flag.as_str() {
            "--sensor-width" => sensor_width = Some(even(flag, value)?),
            "--sensor-height" => sensor_height = Some(even(flag, value)?),
            "--fps" => fps = Some(number(flag, value)?),
            "--video" => video = Some(value.clone()),
            "--sensor" => sensor = Some(value.clone()),
            "--output" => outputs.push(value.as_str()),
            setting => match setting.strip_prefix("--") {
                Some(name) => settings.set(&name.replace('-', "_"), value)?,
                None => return Err(format!("unknown argument {flag}")),
            },
        }
    }
    let sensor_width = sensor_width.ok_or("missing --sensor-width")?;
    let sensor_height = sensor_height.ok_or("missing --sensor-height")?;
    let full = format!("cpu:{sensor_width}x{sensor_height}");
    if outputs.is_empty() {
        outputs.push(&full);
    }
    if outputs.len() > MAX_OUTPUTS {
        return Err(format!("--output: at most {MAX_OUTPUTS} outputs"));
    }
    let mut specs: Vec<OutputSpec> = Vec::with_capacity(outputs.len());
    for value in &outputs {
        let spec = output_spec(value, (sensor_width, sensor_height), &specs)
            .map_err(|message| format!("--output {value}: {message}"))?;
        specs.push(spec);
    }
    let made_for_nothing = (specs.iter().enumerate()).position(|(index, spec)| {
        !spec.send
            && !specs
                .iter()
                .any(|later| later.source == Source::From(index))
    });
    if let Some(index) = made_for_nothing {
        return Err(format!(
            "--output {}: it is not sent and no output is made from it",
            outputs[index]
        ));
    }
    Ok(SingleArguments {
        sensor_width,
        sensor_height,
        fps: fps.ok_or("missing --fps")?,
        camera: Nodes {
            video: video.ok_or("missing --video")?,
            sensor: sensor.ok_or("missing --sensor")?,
        },
        outputs: specs,
        settings,
    })
}

const OUTPUT_FORMS: &str = "cpu:<width>x<height>[:unsent], \
                            from:<index>:<width>x<height>[:unsent] \
                            or from:<index>:<width>x<height>:jpeg:<quality>";

/// The output `value` describes, one of `OUTPUT_FORMS`, of a `sensor`
/// capture, after the outputs `earlier`.
fn output_spec(
    value: &str,
    sensor: (u32, u32),
    earlier: &[OutputSpec],
) -> Result<OutputSpec, String> {
    let (value, send) = match value.strip_suffix(":unsent") {
        Some(made) => (made, false),
        None => (value, true),
    };
    let (source, size, format) = match value.split(':').collect::<Vec<_>>()[..] {
        ["cpu", size] => (None, size, Format::Rgb),
        ["from", index, size] => (Some(output_index(index)?), size, Format::Rgb),
        ["from", _index, _size, "jpeg", _quality] if !send => {
            return Err(format!("a JPEG is always sent: {OUTPUT_FORMS}"))
        }
        ["from", index, size, "jpeg", quality] => {
            (Some(output_index(index)?), size, jpeg(quality)?)
        }
        ["from", _index, _size, format, _quality] => {
            return Err(format!("no format {format}: {OUTPUT_FORMS}"))
        }
        _ => return Err(OUTPUT_FORMS.to_string()),
    };
    let (width, height) = size
        .split_once('x')
        .and_then(|(width, height)| Some((width.parse().ok()?, height.parse().ok()?)))
        .filter(|&(width, height): &(u32, u32)| width > 0 && height > 0)
        .ok_or_else(|| format!("no size {size}"))?;
    let source = match source {
        None => Source::Cpu(
            [Output::Full, Output::Half]
                .into_iter()
                .find(|output| output.size(sensor.0, sensor.1) == (width, height))
                .ok_or_else(|| {
                    format!(
                        "the cpu makes {}x{} or {}x{}",
                        sensor.0,
                        sensor.1,
                        sensor.0 / 2,
                        sensor.1 / 2
                    )
                })?,
        ),
        Some(index) => {
            let from = earlier
                .get(index)
                .ok_or_else(|| format!("no earlier output {index}"))?;
            if let Format::Jpeg { .. } = from.format {
                return Err(format!(
                    "output {index} is a JPEG, which no output is made from"
                ));
            }
            if from.width % width != 0 || from.height % height != 0 {
                return Err(format!(
                    "{width}x{height} is no whole fraction of output {index}'s {}x{}",
                    from.width, from.height
                ));
            }
            Source::From(index)
        }
    };
    Ok(OutputSpec {
        source,
        width,
        height,
        format,
        send,
    })
}

fn output_index(index: &str) -> Result<usize, String> {
    index
        .parse()
        .map_err(|_| format!("no output index {index}"))
}

fn jpeg(quality: &str) -> Result<Format, String> {
    match quality.parse() {
        Ok(quality @ 1..=100) => Ok(Format::Jpeg { quality }),
        _ => Err(format!("a JPEG's quality is 1 to 100, got {quality}")),
    }
}

/// Parses the arguments after the program name: the size and rate, each
/// side's nodes, then any setting as `--name value`, with dashes for
/// underscores. The error is the message to log.
pub fn parse(arguments: &[String]) -> Result<Arguments, String> {
    let (mut width, mut height, mut fps) = (None, None, None);
    let (mut left_node, mut left_subdevice) = (None, None);
    let (mut right_node, mut right_subdevice) = (None, None);
    let mut settings = Settings::default();
    let mut rest = arguments.iter();
    while let Some(flag) = rest.next() {
        let value = rest
            .next()
            .ok_or_else(|| format!("{flag}: missing value"))?;
        match flag.as_str() {
            "--width" => width = Some(number(flag, value)?),
            "--height" => height = Some(number(flag, value)?),
            "--fps" => fps = Some(number(flag, value)?),
            "--left-video" => left_node = Some(value.clone()),
            "--left-sensor" => left_subdevice = Some(value.clone()),
            "--right-video" => right_node = Some(value.clone()),
            "--right-sensor" => right_subdevice = Some(value.clone()),
            setting => match setting.strip_prefix("--") {
                Some(name) => settings.set(&name.replace('-', "_"), value)?,
                None => return Err(format!("unknown argument {flag}")),
            },
        }
    }
    Ok(Arguments {
        width: width.ok_or("missing --width")?,
        height: height.ok_or("missing --height")?,
        fps: fps.ok_or("missing --fps")?,
        left: Nodes {
            video: left_node.ok_or("missing --left-video")?,
            sensor: left_subdevice.ok_or("missing --left-sensor")?,
        },
        right: Nodes {
            video: right_node.ok_or("missing --right-video")?,
            sensor: right_subdevice.ok_or("missing --right-sensor")?,
        },
        settings,
    })
}

/// A sample count that covers whole RGGB cells and fits a record's 16-bit size.
fn even(flag: &str, value: &str) -> Result<u32, String> {
    let samples: u32 = number(flag, value)?;
    if samples > u32::from(u16::MAX) {
        Err(format!("{flag}: at most {} samples, got {value}", u16::MAX))
    } else if samples.is_multiple_of(2) {
        Ok(samples)
    } else {
        Err(format!("{flag}: an even number of samples, got {value}"))
    }
}

fn number<T: FromStr>(flag: &str, value: &str) -> Result<T, String> {
    value
        .parse()
        .map_err(|_| format!("{flag}: invalid value {value}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command_line(extra: &[&str]) -> Vec<String> {
        [
            "--width",
            "768",
            "--height",
            "432",
            "--fps",
            "30",
            "--left-video",
            "vi-output-0",
            "--left-sensor",
            "imx708 5-001a",
            "--right-video",
            "vi-output-4",
            "--right-sensor",
            "imx708 6-001a",
        ]
        .iter()
        .chain(extra)
        .map(|argument| argument.to_string())
        .collect()
    }

    #[test]
    fn parses_the_size_the_nodes_and_the_settings() {
        let arguments = parse(&command_line(&["--black-level", "60"])).unwrap();
        assert_eq!(
            (arguments.width, arguments.height, arguments.fps),
            (768, 432, 30)
        );
        assert_eq!(
            arguments.left,
            Nodes {
                video: "vi-output-0".to_string(),
                sensor: "imx708 5-001a".to_string()
            }
        );
        assert_eq!(arguments.right.sensor, "imx708 6-001a");
        assert_eq!(arguments.settings.black_level, 60);
    }

    #[test]
    fn every_node_is_required() {
        let mut arguments = command_line(&[]);
        arguments.drain(8..10);
        assert_eq!(parse(&arguments), Err("missing --left-sensor".to_string()));
    }

    fn single_command_line(extra: &[&str]) -> Vec<String> {
        [
            "--video",
            "msm_vfe2_video0",
            "--sensor",
            "imx477 5-001a",
            "--sensor-width",
            "2028",
            "--sensor-height",
            "1520",
            "--fps",
            "15",
        ]
        .iter()
        .chain(extra)
        .map(|argument| argument.to_string())
        .collect()
    }

    #[test]
    fn a_single_cameras_black_level_starts_at_its_sensors_wherever_the_sensor_is_named() {
        let ten_bit = |extra: &[&str]| {
            let leading = ["--awb", "1", "--video", "video0", "--sensor-width", "1536"];
            let trailing = [
                "--sensor-height",
                "864",
                "--fps",
                "30",
                "--sensor",
                "imx708",
            ];
            let command_line: Vec<String> = (leading.iter().chain(extra).chain(&trailing))
                .map(|argument| argument.to_string())
                .collect();
            parse_single(&command_line).map(|arguments| arguments.settings.capture.black_level)
        };
        assert_eq!(ten_bit(&[]), Ok(64));
        assert_eq!(ten_bit(&["--black-level", "70"]), Ok(70));
        assert_eq!(
            ten_bit(&["--black-level", "2000"]),
            Err("black_level: invalid value 2000".to_string())
        );
    }

    #[test]
    fn a_capture_size_fits_a_records_16_bit_size() {
        let sized = |width: &str, height: &str| {
            let command_line: Vec<String> = [
                "--video",
                "video0",
                "--sensor",
                "imx477",
                "--fps",
                "15",
                "--sensor-width",
                width,
                "--sensor-height",
                height,
            ]
            .iter()
            .map(|argument| argument.to_string())
            .collect();
            parse_single(&command_line).map(|arguments| arguments.outputs.len())
        };
        assert_eq!(sized("65534", "65534"), Ok(1));
        assert_eq!(
            sized("65536", "1520"),
            Err("--sensor-width: at most 65535 samples, got 65536".to_string())
        );
        assert_eq!(
            sized("2028", "70000"),
            Err("--sensor-height: at most 65535 samples, got 70000".to_string())
        );
    }

    #[test]
    fn the_left_and_right_nodes_select_the_pair() {
        let command_line = command_line(&["--black-level", "60"]);
        assert_eq!(
            parse_command(&command_line),
            Ok(Command::Pair(parse(&command_line).unwrap()))
        );
    }

    #[test]
    fn one_video_node_and_sensor_select_a_single_camera() {
        let command_line = single_command_line(&["--awb", "false", "--red-gain", "1.8"]);
        let Ok(Command::Single(arguments)) = parse_command(&command_line) else {
            panic!("not a single camera: {:?}", parse_command(&command_line));
        };
        assert_eq!(
            (
                arguments.sensor_width,
                arguments.sensor_height,
                arguments.fps
            ),
            (2028, 1520, 15)
        );
        assert_eq!(
            arguments.camera,
            Nodes {
                video: "msm_vfe2_video0".to_string(),
                sensor: "imx477 5-001a".to_string()
            }
        );
        assert!(!arguments.settings.awb);
        assert_eq!(arguments.settings.red_gain, 1.8);
        assert_eq!(arguments.settings.capture.black_level, 256);
    }

    #[test]
    fn a_single_camera_converts_full_size_frames_on_3_threads_and_half_size_ones_on_1() {
        assert_eq!(Output::Full.threads(), 3);
        assert_eq!(Output::Half.threads(), 1);
        let parsed = parse_single(&single_command_line(&["--threads", "4"])).unwrap();
        assert_eq!(parsed.settings.threads, Some(4));
    }

    fn cpu(output: Output, (width, height): (u32, u32)) -> OutputSpec {
        OutputSpec {
            source: Source::Cpu(output),
            width,
            height,
            format: Format::Rgb,
            send: true,
        }
    }

    #[test]
    fn a_single_camera_has_one_output_of_the_capture_size_unless_given_its_outputs() {
        let parsed = |extra: &[&str]| parse_single(&single_command_line(extra)).unwrap();
        assert_eq!(parsed(&[]).outputs, [cpu(Output::Full, (2028, 1520))]);
        assert_eq!(
            parsed(&["--output", "cpu:1014x760"]).outputs,
            [cpu(Output::Half, (1014, 760))]
        );
        assert_eq!(
            parsed(&["--output", "cpu:2028x1520", "--output", "from:0:1014x760"]).outputs,
            [
                cpu(Output::Full, (2028, 1520)),
                OutputSpec {
                    source: Source::From(0),
                    width: 1014,
                    height: 760,
                    format: Format::Rgb,
                    send: true,
                }
            ]
        );
        assert_eq!(
            parsed(&["--output", "cpu:1014x760", "--output", "cpu:2028x1520"]).outputs,
            [
                cpu(Output::Half, (1014, 760)),
                cpu(Output::Full, (2028, 1520))
            ]
        );
    }

    #[test]
    fn an_output_made_from_another_may_be_sent_as_a_jpeg() {
        let parsed = |extra: &[&str]| parse_single(&single_command_line(extra)).unwrap();
        let jpeg = |width, height, quality| OutputSpec {
            source: Source::From(0),
            width,
            height,
            format: Format::Jpeg { quality },
            send: true,
        };
        assert_eq!(
            parsed(&[
                "--output",
                "cpu:2028x1520",
                "--output",
                "from:0:2028x1520:jpeg:80",
                "--output",
                "from:0:1014x760:jpeg:100",
                "--output",
                "from:0:507x380:jpeg:1"
            ])
            .outputs[1..],
            [
                jpeg(2028, 1520, 80),
                jpeg(1014, 760, 100),
                jpeg(507, 380, 1)
            ]
        );
    }

    #[test]
    fn an_output_followed_by_unsent_is_made_but_not_sent() {
        let parsed = parse_single(&single_command_line(&[
            "--output",
            "cpu:2028x1520:unsent",
            "--output",
            "from:0:2028x1520:jpeg:80",
            "--output",
            "from:0:1014x760:unsent",
            "--output",
            "from:2:507x380",
        ]))
        .unwrap();
        let sent: Vec<bool> = parsed.outputs.iter().map(|spec| spec.send).collect();
        assert_eq!(sent, [false, true, false, true]);
        assert_eq!(
            parsed.outputs[0],
            OutputSpec {
                send: false,
                ..cpu(Output::Full, (2028, 1520))
            }
        );
        assert_eq!(
            (parsed.outputs[2].source, parsed.outputs[2].width),
            (Source::From(0), 1014)
        );
    }

    #[test]
    fn an_unsent_output_is_refused_unless_another_is_made_from_it() {
        let refused = |outputs: &[&str]| {
            let extra: Vec<&str> = outputs
                .iter()
                .flat_map(|output| ["--output", output])
                .collect();
            parse_single(&single_command_line(&extra)).unwrap_err()
        };
        assert_eq!(
            refused(&["cpu:2028x1520:unsent"]),
            "--output cpu:2028x1520:unsent: it is not sent and no output is made from it"
        );
        assert_eq!(
            refused(&["cpu:2028x1520", "cpu:1014x760:unsent", "from:0:507x380"]),
            "--output cpu:1014x760:unsent: it is not sent and no output is made from it"
        );
        assert_eq!(
            refused(&["cpu:2028x1520", "from:0:2028x1520:jpeg:80:unsent"]),
            "--output from:0:2028x1520:jpeg:80:unsent: a JPEG is always sent: \
             cpu:<width>x<height>[:unsent], from:<index>:<width>x<height>[:unsent] \
             or from:<index>:<width>x<height>:jpeg:<quality>"
        );
        assert_eq!(
            refused(&["cpu:2028x1520:unsent:unsent", "from:0:1014x760"]),
            "--output cpu:2028x1520:unsent:unsent: cpu:<width>x<height>[:unsent], \
             from:<index>:<width>x<height>[:unsent] \
             or from:<index>:<width>x<height>:jpeg:<quality>"
        );
    }

    #[test]
    fn a_jpeg_output_is_refused_without_its_quality_or_as_a_source() {
        let refused = |output: &str| {
            parse_single(&single_command_line(&[
                "--output",
                "cpu:2028x1520",
                "--output",
                output,
            ]))
            .unwrap_err()
        };
        let forms = "cpu:<width>x<height>[:unsent], from:<index>:<width>x<height>[:unsent] \
                     or from:<index>:<width>x<height>:jpeg:<quality>";
        for quality in ["0", "101", "x", ""] {
            assert_eq!(
                refused(&format!("from:0:2028x1520:jpeg:{quality}")),
                format!(
                    "--output from:0:2028x1520:jpeg:{quality}: \
                     a JPEG's quality is 1 to 100, got {quality}"
                )
            );
        }
        assert_eq!(
            refused("from:0:2028x1520:png:80"),
            format!("--output from:0:2028x1520:png:80: no format png: {forms}")
        );
        assert_eq!(
            refused("from:0:2028x1520:jpeg"),
            format!("--output from:0:2028x1520:jpeg: {forms}")
        );
        assert_eq!(
            refused("cpu:2028x1520:jpeg:80"),
            format!("--output cpu:2028x1520:jpeg:80: {forms}")
        );
        let from_a_jpeg = parse_single(&single_command_line(&[
            "--output",
            "cpu:2028x1520",
            "--output",
            "from:0:2028x1520:jpeg:80",
            "--output",
            "from:1:1014x760",
        ]));
        assert_eq!(
            from_a_jpeg.unwrap_err(),
            "--output from:1:1014x760: output 1 is a JPEG, which no output is made from"
        );
    }

    #[test]
    fn an_output_is_refused_unless_its_processor_or_source_can_make_its_size() {
        let refused = |outputs: &[&str]| {
            let extra: Vec<&str> = outputs
                .iter()
                .flat_map(|output| ["--output", output])
                .collect();
            parse_single(&single_command_line(&extra)).unwrap_err()
        };
        assert_eq!(
            refused(&["cpu:1000x750"]),
            "--output cpu:1000x750: the cpu makes 2028x1520 or 1014x760"
        );
        assert_eq!(
            refused(&["isp:2028x1520"]),
            "--output isp:2028x1520: cpu:<width>x<height>[:unsent], \
             from:<index>:<width>x<height>[:unsent] \
             or from:<index>:<width>x<height>:jpeg:<quality>"
        );
        assert_eq!(refused(&["cpu:2028"]), "--output cpu:2028: no size 2028");
        assert_eq!(
            refused(&["cpu:0x1520"]),
            "--output cpu:0x1520: no size 0x1520"
        );
        assert_eq!(
            refused(&["from:0:1014x760"]),
            "--output from:0:1014x760: no earlier output 0"
        );
        assert_eq!(
            refused(&["cpu:2028x1520", "from:1:1014x760"]),
            "--output from:1:1014x760: no earlier output 1"
        );
        assert_eq!(
            refused(&["cpu:2028x1520", "from:x:1014x760"]),
            "--output from:x:1014x760: no output index x"
        );
        assert_eq!(
            refused(&["cpu:2028x1520", "from:0:1000x760"]),
            "--output from:0:1000x760: 1000x760 is no whole fraction of output 0's 2028x1520"
        );
        let many = vec!["cpu:2028x1520"; MAX_OUTPUTS + 1];
        assert_eq!(refused(&many), "--output: at most 256 outputs");
    }

    #[test]
    fn the_output_size_is_the_capture_size_or_half_of_it() {
        assert_eq!(Output::Full.size(2028, 1520), (2028, 1520));
        assert_eq!(Output::Half.size(2028, 1520), (1014, 760));
    }

    #[test]
    fn a_single_camera_takes_none_of_the_pair_flags() {
        assert_eq!(
            parse_command(&single_command_line(&["--left-video", "vi-output-0"])),
            Err("a single camera (--video, --sensor) takes no --left-video".to_string())
        );
        assert_eq!(
            parse_command(&single_command_line(&["--width", "1014"])),
            Err("a single camera (--video, --sensor) takes no --width".to_string())
        );
    }

    #[test]
    fn a_single_camera_needs_its_nodes_and_an_even_sensor_size() {
        let mut arguments = single_command_line(&[]);
        arguments.drain(6..8);
        assert_eq!(
            parse_command(&arguments),
            Err("missing --sensor-height".to_string())
        );
        assert_eq!(
            parse_command(&single_command_line(&["--sensor-width", "2029"])),
            Err("--sensor-width: an even number of samples, got 2029".to_string())
        );
    }
}
