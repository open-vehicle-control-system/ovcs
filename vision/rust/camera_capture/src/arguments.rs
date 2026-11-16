//! Command line of `camera_capture`.

use framing::output_flag::{self, MAX_OUTPUTS};

use crate::schedule::MIN_MAX_HZ;

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
    /// Each output made beside the frames, in the order of their indices.
    pub outputs: Vec<OutputSpec>,
    /// The most frames a second the outputs are made on, 0 for every frame.
    pub outputs_max_hz: f64,
}

/// One of the outputs made beside the frames from the ISP's second stream.
#[cfg_attr(not(feature = "device"), allow(dead_code))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputSpec {
    /// The ISP's second stream at this size, YUV420, made only for the outputs made from it.
    Isp { width: u32, height: u32 },
    /// A JPEG at `quality`, 1 to 100, of the ISP output of index `from`, at its size.
    Jpeg {
        from: usize,
        width: u32,
        height: u32,
        quality: u8,
    },
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
        outputs: Vec::new(),
        outputs_max_hz: 0.0,
    };
    let mut outputs = Vec::new();
    let mut outputs_max_hz = None;
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
            "--output" => outputs.push(value.as_str()),
            "--outputs-max-hz" => outputs_max_hz = Some(max_hz(flag, value)?),
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    arguments.outputs = output_specs(&outputs)?;
    if let Some(max_hz) = outputs_max_hz {
        if outputs.is_empty() {
            return Err("--outputs-max-hz needs an --output".to_string());
        }
        arguments.outputs_max_hz = max_hz;
    }
    Ok(arguments)
}

const OUTPUT_FORMS: &str =
    "isp:<width>x<height>:unsent or from:<index>:<width>x<height>:jpeg:<quality>";

/// The outputs the `--output` values describe, in their order.
fn output_specs(outputs: &[&str]) -> Result<Vec<OutputSpec>, String> {
    if outputs.len() > MAX_OUTPUTS {
        return Err(format!("--output: at most {MAX_OUTPUTS} outputs"));
    }
    let mut specs: Vec<OutputSpec> = Vec::with_capacity(outputs.len());
    for value in outputs {
        let spec =
            output_spec(value, &specs).map_err(|message| format!("--output {value}: {message}"))?;
        specs.push(spec);
    }
    let made_for_nothing = (specs.iter().enumerate()).position(|(index, spec)| {
        matches!(spec, OutputSpec::Isp { .. })
            && !specs
                .iter()
                .any(|later| matches!(later, OutputSpec::Jpeg { from, .. } if *from == index))
    });
    match made_for_nothing {
        Some(index) => Err(format!(
            "--output {}: it is not sent and no output is made from it",
            outputs[index]
        )),
        None => Ok(specs),
    }
}

/// The output `value` describes, one of `OUTPUT_FORMS`, after the outputs `earlier`.
fn output_spec(value: &str, earlier: &[OutputSpec]) -> Result<OutputSpec, String> {
    let (value, send) = output_flag::strip_unsent(value);
    match value.split(':').collect::<Vec<_>>()[..] {
        ["isp", _size] if send => Err(format!(
            "an ISP output is YUV420, which no record carries: {OUTPUT_FORMS}"
        )),
        ["isp", size] => isp_output(size, earlier),
        ["from", _index, _size, "jpeg", _quality] if !send => {
            Err(format!("a JPEG is always sent: {OUTPUT_FORMS}"))
        }
        ["from", index, size, "jpeg", quality] => {
            jpeg_output(output_flag::index(index)?, size, quality, earlier)
        }
        _ => Err(OUTPUT_FORMS.to_string()),
    }
}

fn isp_output(size: &str, earlier: &[OutputSpec]) -> Result<OutputSpec, String> {
    let (width, height) = output_flag::size(size)?;
    if earlier
        .iter()
        .any(|spec| matches!(spec, OutputSpec::Isp { .. }))
    {
        return Err("the ISP makes one stream beside the frames' own".to_string());
    }
    if width % 2 != 0 || height % 2 != 0 {
        return Err(format!(
            "an ISP output takes an even width and height, not {width}x{height}"
        ));
    }
    if width > u32::from(u16::MAX) || height > u32::from(u16::MAX) {
        return Err(format!(
            "an ISP output is at most {0}x{0}, not {width}x{height}",
            u16::MAX
        ));
    }
    Ok(OutputSpec::Isp { width, height })
}

fn jpeg_output(
    from: usize,
    size: &str,
    quality: &str,
    earlier: &[OutputSpec],
) -> Result<OutputSpec, String> {
    let (width, height) = output_flag::size(size)?;
    let quality = output_flag::jpeg_quality(quality)?;
    match earlier.get(from) {
        None => Err(format!("no earlier output {from}")),
        Some(OutputSpec::Jpeg { .. }) => Err(format!(
            "output {from} is a JPEG, which no output is made from"
        )),
        Some(&OutputSpec::Isp {
            width: from_width,
            height: from_height,
        }) if (from_width, from_height) != (width, height) => Err(format!(
            "{width}x{height} is not output {from}'s {from_width}x{from_height}: no output is scaled"
        )),
        Some(_) => Ok(OutputSpec::Jpeg {
            from,
            width,
            height,
            quality,
        }),
    }
}

fn max_hz(flag: &str, value: &str) -> Result<f64, String> {
    match value.parse::<f64>() {
        Ok(max_hz) if max_hz == 0.0 || (MIN_MAX_HZ..=1000.0).contains(&max_hz) => Ok(max_hz),
        _ => Err(format!(
            "{flag} must be 0 or a number from {MIN_MAX_HZ:.1e} to 1000, got {value}"
        )),
    }
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
                outputs: Vec::new(),
                outputs_max_hz: 0.0,
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
            "--output",
            "isp:1152x648:unsent",
            "--output",
            "from:0:1152x648:jpeg:80",
            "--outputs-max-hz",
            "10",
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
                outputs: vec![
                    OutputSpec::Isp {
                        width: 1152,
                        height: 648
                    },
                    OutputSpec::Jpeg {
                        from: 0,
                        width: 1152,
                        height: 648,
                        quality: 80
                    }
                ],
                outputs_max_hz: 10.0,
            })
        );
    }

    fn outputs(outputs: &[&str]) -> Result<Vec<OutputSpec>, String> {
        let command_line: Vec<&str> = outputs
            .iter()
            .flat_map(|output| ["--output", output])
            .collect();
        parse(&strings(&command_line)).map(|arguments| arguments.outputs)
    }

    #[test]
    fn an_outputs_index_is_its_place_among_the_output_flags() {
        assert_eq!(
            outputs(&[
                "isp:1152x648:unsent",
                "from:0:1152x648:jpeg:80",
                "from:0:1152x648:jpeg:100"
            ]),
            Ok(vec![
                OutputSpec::Isp {
                    width: 1152,
                    height: 648
                },
                OutputSpec::Jpeg {
                    from: 0,
                    width: 1152,
                    height: 648,
                    quality: 80
                },
                OutputSpec::Jpeg {
                    from: 0,
                    width: 1152,
                    height: 648,
                    quality: 100
                }
            ])
        );
    }

    #[test]
    fn an_isp_output_is_refused_unless_unsent_once_at_an_even_size() {
        let refused = |flags: &[&str]| outputs(flags).unwrap_err();
        assert_eq!(
            refused(&["isp:1152x648", "from:0:1152x648:jpeg:80"]),
            format!(
                "--output isp:1152x648: an ISP output is YUV420, which no record carries: \
                 {OUTPUT_FORMS}"
            )
        );
        assert_eq!(
            refused(&["isp:1152x648:unsent", "isp:480x270:unsent"]),
            "--output isp:480x270:unsent: the ISP makes one stream beside the frames' own"
        );
        assert_eq!(
            refused(&["isp:1151x648:unsent", "from:0:1151x648:jpeg:80"]),
            "--output isp:1151x648:unsent: \
             an ISP output takes an even width and height, not 1151x648"
        );
        assert_eq!(
            refused(&["isp:65536x648:unsent", "from:0:65536x648:jpeg:80"]),
            "--output isp:65536x648:unsent: an ISP output is at most 65535x65535, not 65536x648"
        );
        assert_eq!(
            refused(&["isp:1152x648:unsent"]),
            "--output isp:1152x648:unsent: it is not sent and no output is made from it"
        );
        assert_eq!(
            refused(&["isp:0x648:unsent"]),
            "--output isp:0x648:unsent: no size 0x648"
        );
    }

    #[test]
    fn a_jpeg_is_refused_unless_sent_from_an_earlier_isp_output_at_its_size() {
        let refused = |flags: &[&str]| outputs(flags).unwrap_err();
        assert_eq!(
            refused(&["isp:1152x648:unsent", "from:0:576x324:jpeg:80"]),
            "--output from:0:576x324:jpeg:80: \
             576x324 is not output 0's 1152x648: no output is scaled"
        );
        assert_eq!(
            refused(&["from:0:1152x648:jpeg:80"]),
            "--output from:0:1152x648:jpeg:80: no earlier output 0"
        );
        assert_eq!(
            refused(&[
                "isp:1152x648:unsent",
                "from:0:1152x648:jpeg:80",
                "from:1:1152x648:jpeg:80"
            ]),
            "--output from:1:1152x648:jpeg:80: output 1 is a JPEG, which no output is made from"
        );
        assert_eq!(
            refused(&["isp:1152x648:unsent", "from:0:1152x648:jpeg:80:unsent"]),
            format!(
                "--output from:0:1152x648:jpeg:80:unsent: a JPEG is always sent: {OUTPUT_FORMS}"
            )
        );
        assert_eq!(
            refused(&["isp:1152x648:unsent", "from:0:1152x648:jpeg:0"]),
            "--output from:0:1152x648:jpeg:0: a JPEG's quality is 1 to 100, got 0"
        );
        assert_eq!(
            refused(&["isp:1152x648:unsent", "from:x:1152x648:jpeg:80"]),
            "--output from:x:1152x648:jpeg:80: no output index x"
        );
    }

    #[test]
    fn an_output_is_refused_in_a_form_camera_capture_does_not_make() {
        for form in [
            "cpu:1152x648",
            "from:0:576x324",
            "from:0:1152x648:h264:4000:30",
            "from:0:1152x648:png:80",
            "isp",
        ] {
            assert_eq!(
                outputs(&["isp:1152x648:unsent", "from:0:1152x648:jpeg:80", form]),
                Err(format!("--output {form}: {OUTPUT_FORMS}")),
                "{form}"
            );
        }
    }

    #[test]
    fn outputs_are_made_on_every_frame_unless_capped() {
        let flags = [
            "--output",
            "isp:1152x648:unsent",
            "--output",
            "from:0:1152x648:jpeg:80",
        ];
        assert_eq!(parse(&strings(&flags)).unwrap().outputs_max_hz, 0.0);
        for (max_hz, expected) in [("10", 10.0), ("7.5", 7.5), ("10.0", 10.0), ("0", 0.0)] {
            let capped = [&flags[..], &["--outputs-max-hz", max_hz]].concat();
            assert_eq!(parse(&strings(&capped)).unwrap().outputs_max_hz, expected);
        }
    }

    #[test]
    fn an_outputs_cap_is_refused_out_of_range_or_without_outputs() {
        for max_hz in ["-1", "1000.5", "fast", "NaN", "inf"] {
            let flags = [
                "--output",
                "isp:1152x648:unsent",
                "--output",
                "from:0:1152x648:jpeg:80",
                "--outputs-max-hz",
                max_hz,
            ];
            assert_eq!(
                parse(&strings(&flags)),
                Err(format!(
                    "--outputs-max-hz must be 0 or a number from {MIN_MAX_HZ:.1e} to 1000, \
                     got {max_hz}"
                ))
            );
        }
        assert_eq!(
            parse(&strings(&["--outputs-max-hz", "10"])),
            Err("--outputs-max-hz needs an --output".to_string())
        );
    }

    #[test]
    fn an_outputs_cap_whose_interval_overflows_a_capture_time_is_refused() {
        let flags = |max_hz| {
            strings(&[
                "--output",
                "isp:1152x648:unsent",
                "--output",
                "from:0:1152x648:jpeg:80",
                "--outputs-max-hz",
                max_hz,
            ])
        };
        assert_eq!(
            parse(&flags("1e-11")),
            Err(format!(
                "--outputs-max-hz must be 0 or a number from {MIN_MAX_HZ:.1e} to 1000, got 1e-11"
            ))
        );
        assert_eq!(parse(&flags("1e-9")).unwrap().outputs_max_hz, 1e-9);
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
