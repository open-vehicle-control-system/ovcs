//! Conversions between physical settings and the sensor's V4L2 controls.

/// Line time in nanoseconds: the line length in pixels over the pixel rate.
pub fn line_ns(sensor_width: u32, hblank: u32, pixel_rate_hz: u64) -> f64 {
    f64::from(sensor_width + hblank) * 1e9 / pixel_rate_hz as f64
}

/// What differs between the sensors `v4l2_capture` drives.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SensorModel {
    /// Raspberry Pi Camera Module 3, with a lens actuator.
    Imx708,
    /// Global-shutter IMX296, fixed focus.
    Imx296,
    /// Raspberry Pi HQ Camera, 12-bit, with a manual lens.
    Imx477,
}

impl SensorModel {
    /// The model of the sensor whose V4L2 entity is `name` (`imx296 5-001a`);
    /// the IMX708 for any other.
    pub fn for_sensor(name: &str) -> SensorModel {
        if name.starts_with("imx296") {
            SensorModel::Imx296
        } else if name.starts_with("imx477") {
            SensorModel::Imx477
        } else {
            SensorModel::Imx708
        }
    }

    /// The analogue gain code for `gain`, within the control's range.
    pub fn gain_code(self, gain: f64, min_code: i32, max_code: i32) -> i32 {
        let code = match self {
            // gain = 1024 / (1024 - code)
            SensorModel::Imx708 | SensorModel::Imx477 => 1024.0 - 1024.0 / gain,
            // 0.1 dB a code: gain = 10^(code / 200)
            SensorModel::Imx296 => 200.0 * gain.log10(),
        };
        (code.round() as i32).clamp(min_code, max_code)
    }

    /// The gain an analogue gain `code` stands for: the inverse of `gain_code`.
    pub fn gain(self, code: i32) -> f64 {
        match self {
            SensorModel::Imx708 | SensorModel::Imx477 => 1024.0 / f64::from(1024 - code),
            SensorModel::Imx296 => 10f64.powf(f64::from(code) / 200.0),
        }
    }

    /// Whether the camera has a lens actuator to focus.
    pub fn has_lens(self) -> bool {
        self == SensorModel::Imx708
    }

    /// The bits per sample of the mode `v4l2_capture` captures.
    pub fn sample_bits(self) -> u32 {
        match self {
            SensorModel::Imx708 | SensorModel::Imx296 => 10,
            SensorModel::Imx477 => 12,
        }
    }
}

/// The V4L2 name of the lens actuator on the Camera Module 3 whose sensor is
/// named `sensor` (`imx708 <bus>-001a`): the DW9817 at 0x0c on the same bus.
pub fn lens_name(sensor: &str) -> Option<String> {
    let (_, address) = sensor.split_once(' ')?;
    let (bus, _) = address.split_once('-')?;
    Some(format!("dw9807 {bus}-000c"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_time_from_the_sensor_controls() {
        assert!((line_ns(1536, 2_784, 446_400_000) - 9_677.4).abs() < 0.1);
    }

    #[test]
    fn a_camera_module_3_lens_sits_on_its_sensor_bus() {
        assert_eq!(
            lens_name("imx708 5-001a"),
            Some("dw9807 5-000c".to_string())
        );
        assert_eq!(lens_name("imx708"), None);
    }

    #[test]
    fn a_gain_code_reads_back_as_the_gain_it_stands_for() {
        for gain in [2.0, 4.0, 8.0] {
            let code = SensorModel::Imx708.gain_code(gain, 112, 960);
            assert!((SensorModel::Imx708.gain(code) - gain).abs() < 0.02);
        }
    }

    #[test]
    fn a_gain_below_the_lowest_code_reads_back_as_that_code_gain() {
        let code = SensorModel::Imx708.gain_code(1.0, 112, 960);
        assert!((SensorModel::Imx708.gain(code) - 1024.0 / 912.0).abs() < 1e-9);
    }

    #[test]
    fn imx296_gain_codes_round_trip() {
        let model = SensorModel::Imx296;
        for gain in [1.0, 2.0, 8.0, 16.0] {
            let code = model.gain_code(gain, 0, 480);
            assert!((model.gain(code) / gain - 1.0).abs() < 0.006, "gain {gain}");
        }
        assert_eq!(model.gain_code(1.0, 0, 480), 0);
    }

    #[test]
    fn the_model_follows_the_sensor_name() {
        assert_eq!(
            SensorModel::for_sensor("imx296 5-001a"),
            SensorModel::Imx296
        );
        assert_eq!(
            SensorModel::for_sensor("imx708 6-001a"),
            SensorModel::Imx708
        );
        assert!(SensorModel::Imx708.has_lens());
        assert!(!SensorModel::Imx296.has_lens());
    }

    #[test]
    fn the_imx477_is_a_12_bit_sensor_without_a_lens() {
        let model = SensorModel::for_sensor("imx477 5-001a");
        assert_eq!(model, SensorModel::Imx477);
        assert!(!model.has_lens());
        assert_eq!(model.sample_bits(), 12);
        assert_eq!(SensorModel::Imx708.sample_bits(), 10);
        assert_eq!(SensorModel::Imx296.sample_bits(), 10);
    }

    #[test]
    fn imx477_gain_codes_follow_the_mainline_driver() {
        let model = SensorModel::Imx477;
        assert_eq!(model.gain_code(1.0, 0, 978), 0);
        assert_eq!(model.gain_code(2.0, 0, 978), 512);
        assert_eq!(model.gain_code(64.0, 0, 978), 978);
        assert!((model.gain(978) - 1024.0 / 46.0).abs() < 1e-9);
        for gain in [1.5, 4.0, 16.0] {
            let code = model.gain_code(gain, 0, 978);
            assert!((model.gain(code) / gain - 1.0).abs() < 0.02, "gain {gain}");
        }
    }

    #[test]
    fn imx708_gain_codes() {
        assert_eq!(SensorModel::Imx708.gain_code(1.0, 112, 960), 112);
        assert_eq!(SensorModel::Imx708.gain_code(2.0, 112, 960), 512);
        assert_eq!(SensorModel::Imx708.gain_code(8.0, 112, 960), 896);
    }
}
