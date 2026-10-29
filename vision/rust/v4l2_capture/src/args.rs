//! Command line of `v4l2_capture`.

use std::str::FromStr;

use crate::settings::Settings;

#[derive(Clone, Debug, PartialEq)]
pub struct Args {
    /// Output size; the sensor runs at twice this in each axis.
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub settings: Settings,
}

/// Parses the arguments after the program name: the size and rate, then any
/// setting as `--name value`, with dashes for underscores. The error is the
/// message to log.
pub fn parse(args: &[String]) -> Result<Args, String> {
    let (mut width, mut height, mut fps) = (None, None, None);
    let mut settings = Settings::default();
    let mut rest = args.iter();
    while let Some(flag) = rest.next() {
        let value = rest
            .next()
            .ok_or_else(|| format!("{flag}: missing value"))?;
        match flag.as_str() {
            "--width" => width = Some(number(flag, value)?),
            "--height" => height = Some(number(flag, value)?),
            "--fps" => fps = Some(number(flag, value)?),
            setting => match setting.strip_prefix("--") {
                Some(name) => settings
                    .set(&name.replace('-', "_"), value)
                    .map_err(|error| error.replace("unknown setting", "unknown arg"))?,
                None => return Err(format!("unknown arg {flag}")),
            },
        }
    }
    Ok(Args {
        width: width.ok_or("missing --width")?,
        height: height.ok_or("missing --height")?,
        fps: fps.ok_or("missing --fps")?,
        settings,
    })
}

fn number<T: FromStr>(flag: &str, value: &str) -> Result<T, String> {
    value
        .parse()
        .map_err(|_| format!("{flag}: invalid value {value}"))
}
