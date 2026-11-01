//! Command line of `v4l2_capture`.

use std::str::FromStr;

use crate::settings::Settings;

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

/// The V4L2 names of one side's capture node and sensor subdevice.
#[derive(Clone, Debug, PartialEq)]
pub struct Nodes {
    pub video: String,
    pub sensor: String,
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
}
