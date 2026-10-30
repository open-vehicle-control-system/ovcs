//! The capture settings: set at start from the command line, and while
//! running from `name=value` records on stdin.

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    /// 0, or 180 for sensors mounted upside down.
    pub rotation: u16,
    pub auto_exposure: bool,
    /// The exposure time and analogue gain: fixed without auto exposure,
    /// where it starts with them.
    pub exposure_us: u32,
    pub analogue_gain: f64,
    /// Auto exposure's mean grey, and the most exposure time and gain it uses.
    pub target_brightness: f64,
    pub max_exposure_us: u32,
    pub max_gain: f64,
    /// The raw sample value of black, and the gamma the grey image is encoded with.
    pub black_level: u16,
    pub gamma: f64,
    /// Both lens actuators' position, 0 to 1023 (512 unpowered); 428 is about
    /// 1.5 to 2 m on the Camera Module 3 Wide.
    pub focus: u16,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            rotation: 0,
            auto_exposure: true,
            exposure_us: 8_000,
            analogue_gain: 2.0,
            target_brightness: 110.0,
            max_exposure_us: 20_000,
            max_gain: 16.0,
            black_level: 64,
            gamma: 2.2,
            focus: 428,
        }
    }
}

impl Settings {
    /// Sets `name` (as in the struct) from `value`. The error is the message to log.
    pub fn set(&mut self, name: &str, value: &str) -> Result<(), String> {
        let invalid = || format!("{name}: invalid value {value}");
        match name {
            "rotation" => {
                self.rotation = match value {
                    "0" => 0,
                    "180" => 180,
                    _ => return Err(format!("{name}: 0 or 180, got {value}")),
                }
            }
            "auto_exposure" => {
                self.auto_exposure = match value {
                    "1" | "true" => true,
                    "0" | "false" => false,
                    _ => return Err(invalid()),
                }
            }
            "exposure_us" => {
                self.exposure_us = in_range(value, 100.0, 1_000_000.0).ok_or_else(invalid)? as u32
            }
            "analogue_gain" => {
                self.analogue_gain = in_range(value, 1.0, 16.0).ok_or_else(invalid)?
            }
            "target_brightness" => {
                self.target_brightness = in_range(value, 1.0, 254.0).ok_or_else(invalid)?
            }
            "max_exposure_us" => {
                self.max_exposure_us =
                    in_range(value, 100.0, 1_000_000.0).ok_or_else(invalid)? as u32
            }
            "max_gain" => self.max_gain = in_range(value, 1.0, 16.0).ok_or_else(invalid)?,
            "black_level" => {
                self.black_level = in_range(value, 0.0, 1022.0).ok_or_else(invalid)? as u16
            }
            "gamma" => self.gamma = in_range(value, 0.5, 4.0).ok_or_else(invalid)?,
            "focus" => self.focus = in_range(value, 0.0, 1023.0).ok_or_else(invalid)? as u16,
            _ => return Err(format!("unknown setting {name}")),
        }
        Ok(())
    }

    /// Applies a `name=value` record.
    pub fn apply(&mut self, record: &[u8]) -> Result<(), String> {
        let record =
            std::str::from_utf8(record).map_err(|_| "a setting is not UTF-8".to_string())?;
        let (name, value) = record
            .split_once('=')
            .ok_or_else(|| format!("not name=value: {record}"))?;
        self.set(name.trim(), value.trim())
    }
}

fn in_range(value: &str, min: f64, max: f64) -> Option<f64> {
    value
        .parse::<f64>()
        .ok()
        .filter(|v| (min..=max).contains(v))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_change_one_setting_each() {
        let mut settings = Settings::default();
        settings.apply(b"rotation=180").unwrap();
        settings.apply(b"auto_exposure=0").unwrap();
        settings.apply(b"gamma=1.8").unwrap();
        assert_eq!(settings.rotation, 180);
        assert!(!settings.auto_exposure);
        assert_eq!(settings.gamma, 1.8);
    }

    #[test]
    fn focuses_both_lenses_at_about_one_and_a_half_to_two_metres_by_default() {
        let mut settings = Settings::default();
        assert_eq!(settings.focus, 428);
        settings.apply(b"focus=512").unwrap();
        assert_eq!(settings.focus, 512);
        assert!(settings.apply(b"focus=1024").is_err());
    }

    #[test]
    fn rejects_unknown_names_and_values_out_of_range() {
        let mut settings = Settings::default();
        assert_eq!(
            settings.apply(b"zoom=2"),
            Err("unknown setting zoom".to_string())
        );
        assert_eq!(
            settings.apply(b"rotation=90"),
            Err("rotation: 0 or 180, got 90".to_string())
        );
        assert!(settings.apply(b"max_gain=40").is_err());
        assert!(settings.apply(b"gamma").is_err());
        assert_eq!(settings, Settings::default());
    }
}
