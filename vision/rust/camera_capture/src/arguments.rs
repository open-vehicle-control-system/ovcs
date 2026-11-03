//! Command line of `camera_capture`.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncMode {
    Off,
    Server,
    Client,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExposureMode {
    Normal,
    Short,
    Long,
}

/// How each frame is written: a JPEG FRAME record or a GREY_FRAME record of its luma.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Jpeg,
    Grey,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SensorMode {
    pub width: u32,
    pub height: u32,
    pub bit_depth: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Arguments {
    pub camera_id: u32,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    /// Validated against 0/90/180/270 when the camera is configured.
    pub rotation: u32,
    pub sync_mode: SyncMode,
    /// `None` leaves libcamera's default (normal).
    pub exposure_mode: Option<ExposureMode>,
    /// Dioptres; `None` or negative leaves the lens where libcamera puts it.
    pub lens_position: Option<f32>,
    /// `None` lets libcamera pick a mode from the output size.
    pub sensor_mode: Option<SensorMode>,
    pub format: Format,
}

/// Parses the arguments after the program name. The error is the warning to log.
pub fn parse(command_line: &[String]) -> Result<Arguments, String> {
    let mut arguments = Arguments {
        camera_id: 0,
        width: 1280,
        height: 720,
        fps: 30,
        rotation: 0,
        sync_mode: SyncMode::Off,
        exposure_mode: None,
        lens_position: None,
        sensor_mode: None,
        format: Format::Jpeg,
    };
    let mut rest = command_line.iter();
    while let Some(flag) = rest.next() {
        let Some(value) = rest.next() else {
            return Err(format!("unknown argument {flag}"));
        };
        match flag.as_str() {
            "--camera" => arguments.camera_id = unsigned(flag, value)?,
            "--width" => arguments.width = unsigned(flag, value)?,
            "--height" => arguments.height = unsigned(flag, value)?,
            "--fps" => arguments.fps = unsigned(flag, value)?,
            "--rotation" => arguments.rotation = unsigned(flag, value)?,
            "--sync" => {
                arguments.sync_mode = match value.as_str() {
                    "server" => SyncMode::Server,
                    "client" => SyncMode::Client,
                    _ => return Err("--sync must be server or client".to_string()),
                }
            }
            "--exposure-mode" => {
                arguments.exposure_mode = Some(match value.as_str() {
                    "normal" => ExposureMode::Normal,
                    "short" => ExposureMode::Short,
                    "long" => ExposureMode::Long,
                    _ => return Err("--exposure-mode must be normal, short or long".to_string()),
                })
            }
            "--lens-position" => {
                arguments.lens_position = Some(
                    value
                        .parse()
                        .map_err(|_| format!("{flag} must be a number, got {value}"))?,
                )
            }
            "--sensor-mode" => {
                arguments.sensor_mode =
                    Some(sensor_mode(value).ok_or_else(|| {
                        "--sensor-mode must be WIDTHxHEIGHT[:BITDEPTH]".to_string()
                    })?)
            }
            "--format" => {
                arguments.format = match value.as_str() {
                    "jpeg" => Format::Jpeg,
                    "grey" => Format::Grey,
                    _ => return Err("--format must be jpeg or grey".to_string()),
                }
            }
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    Ok(arguments)
}

fn unsigned(flag: &str, value: &str) -> Result<u32, String> {
    value
        .parse()
        .map_err(|_| format!("{flag} must be a non-negative integer, got {value}"))
}

/// `WIDTHxHEIGHT` or `WIDTHxHEIGHT:BITDEPTH`, the bit depth 10 by default.
fn sensor_mode(value: &str) -> Option<SensorMode> {
    let (size, bit_depth) = match value.split_once(':') {
        Some((size, bits)) => (size, bits.parse().ok()?),
        None => (value, 10),
    };
    let (width, height) = size.split_once('x')?;
    let mode = SensorMode {
        width: width.parse().ok()?,
        height: height.parse().ok()?,
        bit_depth,
    };
    (mode.width > 0 && mode.height > 0).then_some(mode)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(arguments: &[&str]) -> Vec<String> {
        arguments.iter().map(|a| a.to_string()).collect()
    }

    #[test]
    fn parses_defaults() {
        assert_eq!(
            parse(&[]),
            Ok(Arguments {
                camera_id: 0,
                width: 1280,
                height: 720,
                fps: 30,
                rotation: 0,
                sync_mode: SyncMode::Off,
                exposure_mode: None,
                lens_position: None,
                sensor_mode: None,
                format: Format::Jpeg,
            })
        );
    }

    #[test]
    fn parses_every_flag() {
        let arguments = strings(&[
            "--camera",
            "1",
            "--width",
            "640",
            "--height",
            "480",
            "--fps",
            "15",
            "--rotation",
            "180",
            "--sync",
            "client",
            "--exposure-mode",
            "short",
            "--lens-position",
            "1.5",
            "--sensor-mode",
            "2304x1296:12",
            "--format",
            "grey",
        ]);
        assert_eq!(
            parse(&arguments),
            Ok(Arguments {
                camera_id: 1,
                width: 640,
                height: 480,
                fps: 15,
                rotation: 180,
                sync_mode: SyncMode::Client,
                exposure_mode: Some(ExposureMode::Short),
                lens_position: Some(1.5),
                sensor_mode: Some(SensorMode {
                    width: 2304,
                    height: 1296,
                    bit_depth: 12
                }),
                format: Format::Grey,
            })
        );
    }

    #[test]
    fn parses_server_sync_and_other_exposure_modes() {
        let arguments = parse(&strings(&["--sync", "server", "--exposure-mode", "long"])).unwrap();
        assert_eq!(arguments.sync_mode, SyncMode::Server);
        assert_eq!(arguments.exposure_mode, Some(ExposureMode::Long));
        let arguments = parse(&strings(&["--exposure-mode", "normal"])).unwrap();
        assert_eq!(arguments.exposure_mode, Some(ExposureMode::Normal));
    }

    #[test]
    fn rejects_bad_sync_mode() {
        assert_eq!(
            parse(&strings(&["--sync", "leader"])),
            Err("--sync must be server or client".to_string())
        );
    }

    #[test]
    fn rejects_bad_exposure_mode() {
        assert_eq!(
            parse(&strings(&["--exposure-mode", "auto"])),
            Err("--exposure-mode must be normal, short or long".to_string())
        );
    }

    #[test]
    fn rejects_bad_sensor_mode() {
        for mode in [
            "2304",
            "2304x",
            "x1296",
            "2304x1296:",
            "2304x1296:ten",
            "0x1296",
            "wxh",
        ] {
            assert_eq!(
                parse(&strings(&["--sensor-mode", mode])),
                Err("--sensor-mode must be WIDTHxHEIGHT[:BITDEPTH]".to_string()),
                "{mode}"
            );
        }
    }

    #[test]
    fn sensor_mode_without_bits_defaults_to_10() {
        let arguments = parse(&strings(&["--sensor-mode", "2304x1296"])).unwrap();
        assert_eq!(
            arguments.sensor_mode,
            Some(SensorMode {
                width: 2304,
                height: 1296,
                bit_depth: 10
            })
        );
    }

    #[test]
    fn parses_jpeg_format_and_rejects_others() {
        let arguments = parse(&strings(&["--format", "jpeg"])).unwrap();
        assert_eq!(arguments.format, Format::Jpeg);
        assert_eq!(
            parse(&strings(&["--format", "rgb"])),
            Err("--format must be jpeg or grey".to_string())
        );
    }

    #[test]
    fn rejects_unknown_flag() {
        assert_eq!(
            parse(&strings(&["--zoom", "2"])),
            Err("unknown argument --zoom".to_string())
        );
    }

    #[test]
    fn rejects_flag_without_value() {
        assert_eq!(
            parse(&strings(&["--width"])),
            Err("unknown argument --width".to_string())
        );
    }

    #[test]
    fn rejects_malformed_numbers() {
        assert_eq!(
            parse(&strings(&["--width", "wide"])),
            Err("--width must be a non-negative integer, got wide".to_string())
        );
        assert_eq!(
            parse(&strings(&["--camera", "-1"])),
            Err("--camera must be a non-negative integer, got -1".to_string())
        );
        assert_eq!(
            parse(&strings(&["--lens-position", "near"])),
            Err("--lens-position must be a number, got near".to_string())
        );
    }
}
