//! Conversions between physical settings and the sensor's V4L2 controls.

/// Line time in nanoseconds: the line length in pixels over the pixel rate.
pub fn line_ns(sensor_width: u32, hblank: u32, pixel_rate_hz: u64) -> f64 {
    f64::from(sensor_width + hblank) * 1e9 / pixel_rate_hz as f64
}

/// The IMX708's analogue gain code for `gain`, where gain = 1024 / (1024 - code).
pub fn imx708_gain_code(gain: f64, min: i32, max: i32) -> i32 {
    ((1024.0 - 1024.0 / gain).round() as i32).clamp(min, max)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_time_from_the_sensor_controls() {
        assert!((line_ns(1536, 2_784, 446_400_000) - 9_677.4).abs() < 0.1);
    }

    #[test]
    fn imx708_gain_codes() {
        assert_eq!(imx708_gain_code(1.0, 112, 960), 112);
        assert_eq!(imx708_gain_code(2.0, 112, 960), 512);
        assert_eq!(imx708_gain_code(8.0, 112, 960), 896);
    }
}
