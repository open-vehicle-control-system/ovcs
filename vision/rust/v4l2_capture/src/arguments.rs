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
    /// The capture size; the output is half of it in each axis.
    pub sensor_width: u32,
    pub sensor_height: u32,
    pub fps: u32,
    pub camera: Nodes,
    pub settings: ColourSettings,
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
/// then any setting as `--name value`, with dashes for underscores. The
/// error is the message to log.
pub fn parse_single(arguments: &[String]) -> Result<SingleArguments, String> {
    let (mut sensor_width, mut sensor_height, mut fps) = (None, None, None);
    let (mut video, mut sensor) = (None, None);
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
            setting => match setting.strip_prefix("--") {
                Some(name) => settings.set(&name.replace('-', "_"), value)?,
                None => return Err(format!("unknown argument {flag}")),
            },
        }
    }
    Ok(SingleArguments {
        sensor_width: sensor_width.ok_or("missing --sensor-width")?,
        sensor_height: sensor_height.ok_or("missing --sensor-height")?,
        fps: fps.ok_or("missing --fps")?,
        camera: Nodes {
            video: video.ok_or("missing --video")?,
            sensor: sensor.ok_or("missing --sensor")?,
        },
        settings,
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
