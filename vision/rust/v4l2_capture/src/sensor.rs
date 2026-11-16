//! Conversions between physical settings and the sensor's V4L2 controls.

use std::io;

use crate::tuning::{self, Tuning};
use crate::v4l2::{self, Node};

// The exposure ends this many lines before the frame does.
const EXPOSURE_MARGIN_LINES: i32 = 8;

/// Line time in nanoseconds: the line length in pixels over the pixel rate.
pub fn line_ns(sensor_width: u32, hblank: u32, pixel_rate_hz: u64) -> f64 {
    f64::from(sensor_width + hblank) * 1e9 / pixel_rate_hz as f64
}

/// The line time of a sensor's frames and the vertical blanking that runs
/// them at a frame rate.
pub struct FrameTiming {
    pub line_ns: f64,
    /// The VBLANK that gives the frame rate, within the control's range.
    pub vblank: i32,
    pub vblank_min: i32,
    pub vblank_max: i32,
    pub period_ns: i64,
    sensor_height: u32,
}

impl FrameTiming {
    /// The timing of `sensor_width` x `sensor_height` frames at `fps`, the line
    /// time read from `line_sensor` and the VBLANK range from `vblank_sensor`.
    pub fn read(
        line_sensor: &Node,
        vblank_sensor: &Node,
        (sensor_width, sensor_height): (u32, u32),
        fps: u32,
    ) -> io::Result<FrameTiming> {
        let hblank = line_sensor.control(v4l2::CID_HBLANK)?;
        let pixel_rate = line_sensor.control64(v4l2::CID_PIXEL_RATE)?;
        let line_ns = line_ns(sensor_width, hblank as u32, pixel_rate as u64);
        let (vblank_min, vblank_max) = vblank_sensor.control_range(v4l2::CID_VBLANK)?;
        let frame_lines = (1e9 / f64::from(fps) / line_ns).round() as i32;
        let vblank = (frame_lines - sensor_height as i32).clamp(vblank_min, vblank_max);
        let period_ns = (f64::from(sensor_height as i32 + vblank) * line_ns).round() as i64;
        Ok(FrameTiming {
            line_ns,
            vblank,
            vblank_min,
            vblank_max,
            period_ns,
            sensor_height,
        })
    }

    pub fn frame_us(&self) -> f64 {
        self.period_ns as f64 / 1_000.0
    }

    /// The exposure lines closest to `exposure_us` that fit in a frame.
    pub fn exposure_lines(&self, exposure_us: f64) -> i32 {
        let max_lines = self.sensor_height as i32 + self.vblank - EXPOSURE_MARGIN_LINES;
        ((exposure_us * 1_000.0 / self.line_ns).round() as i32).clamp(1, max_lines)
    }

    /// The exposure time of `lines` exposure lines.
    pub fn exposure_us(&self, lines: i32) -> f64 {
        f64::from(lines) * self.line_ns / 1_000.0
    }
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

/// The sample value of black in 10 bits.
const BLACK_LEVEL_10_BIT: u16 = 64;

impl SensorModel {
    /// The model of the sensor whose V4L2 entity is `name` (`imx296 5-001a`),
    /// `None` for a sensor of another model.
    pub fn for_sensor(name: &str) -> Option<SensorModel> {
        [
            ("imx708", SensorModel::Imx708),
            ("imx296", SensorModel::Imx296),
            ("imx477", SensorModel::Imx477),
        ]
        .into_iter()
        .find_map(|(prefix, model)| name.starts_with(prefix).then_some(model))
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

    /// The colour tuning of the sensor, if it has one.
    pub fn tuning(self) -> Option<&'static Tuning> {
        match self {
            SensorModel::Imx477 => Some(&tuning::imx477::TUNING),
            SensorModel::Imx708 | SensorModel::Imx296 => None,
        }
    }

    /// The sample value of black a colour camera starts from, at the sensor's depth.
    pub fn black_level(self) -> u16 {
        BLACK_LEVEL_10_BIT << (self.sample_bits() - 10)
    }

    /// The bits per sample of the mode `v4l2_capture` captures.
    pub fn sample_bits(self) -> u32 {
        match self {
            SensorModel::Imx708 | SensorModel::Imx296 => 10,
            SensorModel::Imx477 => 12,
        }
    }
}

/// A rectangle of a sensor's pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rectangle {
    pub left: i32,
    pub top: i32,
    pub width: u32,
    pub height: u32,
}

/// Where a frame lies on its sensor: the rectangle `crop` it is read from,
/// binned or not, within `bounds`, the rectangle the sensor can read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SensorCrop {
    pub crop: Rectangle,
    pub bounds: Rectangle,
}

impl std::fmt::Display for SensorCrop {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Rectangle {
            left,
            top,
            width,
            height,
        } = self.crop;
        let bounds = self.bounds;
        write!(
            formatter,
            "{width}x{height} at ({left}, {top}) of {}x{} at ({}, {})",
            bounds.width, bounds.height, bounds.left, bounds.top
        )
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
            Some(SensorModel::Imx296)
        );
        assert_eq!(
            SensorModel::for_sensor("imx708 6-001a"),
            Some(SensorModel::Imx708)
        );
        assert_eq!(SensorModel::for_sensor("imx219 10-0010"), None);
        assert!(SensorModel::Imx708.has_lens());
        assert!(!SensorModel::Imx296.has_lens());
    }

    #[test]
    fn the_imx477_is_a_12_bit_sensor_without_a_lens() {
        let model = SensorModel::for_sensor("imx477 5-001a").unwrap();
        assert_eq!(model, SensorModel::Imx477);
        assert!(!model.has_lens());
        assert_eq!(model.sample_bits(), 12);
        assert_eq!(SensorModel::Imx708.sample_bits(), 10);
        assert_eq!(SensorModel::Imx296.sample_bits(), 10);
    }

    #[test]
    fn only_the_imx477_has_a_colour_tuning() {
        assert!(SensorModel::Imx477.tuning().is_some());
        assert!(SensorModel::Imx708.tuning().is_none());
        assert!(SensorModel::Imx296.tuning().is_none());
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
