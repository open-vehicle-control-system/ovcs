//! Runtime controls from stdin: one `Name=value` per record, a libcamera
//! control by its name. The value is parsed here; its type comes from
//! libcamera's control id when the control is applied.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ControlValue {
    Integer(i64),
    Float(f32),
}

/// The scalar libcamera control types a command can set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlKind {
    Bool,
    Int32,
    Int64,
    Float,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TypedValue {
    Bool(bool),
    Int32(i32),
    Int64(i64),
    Float(f32),
}

/// Splits a command into the control's name and its value.
pub fn parse_control(line: &str) -> Result<(String, ControlValue), String> {
    let (name, value) = line
        .split_once('=')
        .ok_or_else(|| "expected Name=value".to_string())?;
    if name.is_empty() {
        return Err("empty control name".to_string());
    }
    let value = if let Ok(integer) = value.parse() {
        ControlValue::Integer(integer)
    } else if let Ok(float) = value.parse() {
        ControlValue::Float(float)
    } else {
        return Err(format!("{name}: {value:?} is not a number"));
    };
    Ok((name.to_string(), value))
}

/// `value` as a `kind` control: a bool is 0 or 1, an integer control takes
/// no fraction, a float control takes either. `None` when it does not fit.
pub fn coerce(value: ControlValue, kind: ControlKind) -> Option<TypedValue> {
    match (kind, value) {
        (ControlKind::Bool, ControlValue::Integer(0)) => Some(TypedValue::Bool(false)),
        (ControlKind::Bool, ControlValue::Integer(1)) => Some(TypedValue::Bool(true)),
        (ControlKind::Int32, ControlValue::Integer(i)) => {
            i32::try_from(i).ok().map(TypedValue::Int32)
        }
        (ControlKind::Int64, ControlValue::Integer(i)) => Some(TypedValue::Int64(i)),
        (ControlKind::Float, ControlValue::Integer(i)) => Some(TypedValue::Float(i as f32)),
        (ControlKind::Float, ControlValue::Float(f)) => Some(TypedValue::Float(f)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_float_control() {
        assert_eq!(
            parse_control("LensPosition=2.5"),
            Ok(("LensPosition".to_string(), ControlValue::Float(2.5)))
        );
    }

    #[test]
    fn parses_int_control() {
        assert_eq!(
            parse_control("AeExposureMode=1"),
            Ok(("AeExposureMode".to_string(), ControlValue::Integer(1)))
        );
        assert_eq!(
            parse_control("ExposureTime=-20000"),
            Ok(("ExposureTime".to_string(), ControlValue::Integer(-20000)))
        );
    }

    #[test]
    fn rejects_line_without_equals() {
        assert!(parse_control("LensPosition").is_err());
    }

    #[test]
    fn rejects_empty_name_or_value_and_non_numbers() {
        assert!(parse_control("=1").is_err());
        assert!(parse_control("LensPosition=").is_err());
        assert!(parse_control("LensPosition=near").is_err());
        assert!(parse_control("LensPosition=1.5x").is_err());
    }

    #[test]
    fn parses_every_command_the_elixir_driver_sends() {
        for line in [
            "AeExposureMode=0",
            "ExposureTimeMode=1",
            "ExposureTime=10000",
            "AnalogueGainMode=1",
            "AnalogueGain=4.0",
            "AfMode=0",
            "LensPosition=1.5",
            "Brightness=-0.25",
            "Contrast=1.0",
            "Sharpness=1.0",
            "NoiseReductionMode=2",
        ] {
            assert!(parse_control(line).is_ok(), "{line}");
        }
    }

    #[test]
    fn coerces_to_the_control_type() {
        use ControlValue::*;
        assert_eq!(
            coerce(Integer(1), ControlKind::Bool),
            Some(TypedValue::Bool(true))
        );
        assert_eq!(
            coerce(Integer(0), ControlKind::Bool),
            Some(TypedValue::Bool(false))
        );
        assert_eq!(coerce(Integer(2), ControlKind::Bool), None);
        assert_eq!(coerce(Float(1.0), ControlKind::Bool), None);
        assert_eq!(
            coerce(Integer(7), ControlKind::Int32),
            Some(TypedValue::Int32(7))
        );
        assert_eq!(coerce(Integer(1 << 40), ControlKind::Int32), None);
        assert_eq!(coerce(Float(1.5), ControlKind::Int32), None);
        assert_eq!(
            coerce(Integer(1 << 40), ControlKind::Int64),
            Some(TypedValue::Int64(1 << 40))
        );
        assert_eq!(coerce(Float(1.5), ControlKind::Int64), None);
        assert_eq!(
            coerce(Float(1.5), ControlKind::Float),
            Some(TypedValue::Float(1.5))
        );
        assert_eq!(
            coerce(Integer(2), ControlKind::Float),
            Some(TypedValue::Float(2.0))
        );
    }
}
