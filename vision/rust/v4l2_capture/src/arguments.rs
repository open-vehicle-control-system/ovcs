//! Command line of `v4l2_capture`.

use std::str::FromStr;

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

/// One of a single camera's outputs: the size of its RGB frames and what
/// makes them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutputSpec {
    pub source: Source,
    pub width: u32,
    pub height: u32,
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
/// earlier output to a whole fraction of its size; without, one output of
/// the capture's size. The error is the message to log.
pub fn parse_single(arguments: &[String]) -> Result<SingleArguments, String> {
    let (mut sensor_width, mut sensor_height, mut fps) = (None, None, None);
    let (mut video, mut sensor) = (None, None);
    let mut outputs = Vec::new();
    let mut settings = ColourSettings::default();
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
    for value in outputs {
        let spec = output_spec(value, (sensor_width, sensor_height), &specs)
            .map_err(|message| format!("--output {value}: {message}"))?;
        specs.push(spec);
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

/// The output `value` describes, `cpu:<width>x<height>` or
/// `from:<index>:<width>x<height>`, of a `sensor` capture, after the
/// outputs `earlier`.
fn output_spec(
    value: &str,
    sensor: (u32, u32),
    earlier: &[OutputSpec],
) -> Result<OutputSpec, String> {
    let (source, size) = match value.split(':').collect::<Vec<_>>()[..] {
        ["cpu", size] => (None, size),
        ["from", index, size] => {
            let index: usize = index
                .parse()
                .map_err(|_| format!("no output index {index}"))?;
            (Some(index), size)
        }
        _ => return Err("cpu:<width>x<height> or from:<index>:<width>x<height>".to_string()),
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
    })
}

/// Parses the arguments after the program name: the size and rate, each
/// side's nodes, then any setting as `--name value`, with dashes for
/// underscores. The error is the message to log.
pub fn parse(arguments: &[String]) -> Result<Arguments, String> {
    let (mut width, mut height, mut fps) = (None, None, None);
    let (mut left_video, mut left_sensor) = (None, None);
    let (mut right_video, mut right_sensor) = (None, None);
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
            "--left-video" => left_video = Some(value.clone()),
            "--left-sensor" => left_sensor = Some(value.clone()),
            "--right-video" => right_video = Some(value.clone()),
            "--right-sensor" => right_sensor = Some(value.clone()),
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
            video: left_video.ok_or("missing --left-video")?,
            sensor: left_sensor.ok_or("missing --left-sensor")?,
        },
        right: Nodes {
            video: right_video.ok_or("missing --right-video")?,
            sensor: right_sensor.ok_or("missing --right-sensor")?,
        },
        settings,
    })
}

/// A sample count that covers whole RGGB cells.
fn even(flag: &str, value: &str) -> Result<u32, String> {
    let samples: u32 = number(flag, value)?;
    if samples.is_multiple_of(2) {
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
                    height: 760
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
            "--output isp:2028x1520: cpu:<width>x<height> or from:<index>:<width>x<height>"
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
