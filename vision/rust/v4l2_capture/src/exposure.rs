//! Automatic exposure for sensors without an ISP to run one.

/// Steers the mean grey of the image to `target` by changing the exposure
/// time first, up to `max_exposure_us`, then the analogue gain, up to
/// `max_gain`. Brightness is gamma-encoded, so the light needed scales with
/// the brightness ratio to the power `gamma`; each step at most doubles or
/// halves it, against oscillation while the sensor applies the last one.
pub struct AutoExposure {
    pub exposure_us: f64,
    pub gain: f64,
    pub max_exposure_us: f64,
    pub max_gain: f64,
    pub target: f64,
    pub gamma: f64,
}

const MIN_EXPOSURE_US: f64 = 100.0;
const DEADBAND: f64 = 0.08;

impl AutoExposure {
    /// The new `{exposure_us, gain}` for an image of mean grey `mean`, or
    /// `None` when it is close enough to the target.
    pub fn observe(&mut self, mean: f64) -> Option<(f64, f64)> {
        let ratio = self.target / mean.max(1.0);
        if (ratio - 1.0).abs() < DEADBAND {
            return None;
        }
        let light = (self.exposure_us * self.gain * ratio.powf(self.gamma).clamp(0.5, 2.0))
            .clamp(MIN_EXPOSURE_US, self.max_exposure_us * self.max_gain);
        let exposure_us = light.min(self.max_exposure_us);
        let gain = (light / exposure_us).clamp(1.0, self.max_gain);
        if (exposure_us, gain) == (self.exposure_us, self.gain) {
            return None;
        }
        self.exposure_us = exposure_us;
        self.gain = gain;
        Some((exposure_us, gain))
    }
}

/// Mean of every `stride`-th byte of `image`.
pub fn mean(image: &[u8], stride: usize) -> f64 {
    let (sum, count) = image
        .iter()
        .step_by(stride.max(1))
        .fold((0u64, 0u64), |(sum, count), v| {
            (sum + u64::from(*v), count + 1)
        });
    if count == 0 {
        0.0
    } else {
        sum as f64 / count as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn auto_exposure(exposure_us: f64, gain: f64) -> AutoExposure {
        AutoExposure {
            exposure_us,
            gain,
            max_exposure_us: 20_000.0,
            max_gain: 16.0,
            target: 110.0,
            gamma: 2.2,
        }
    }

    #[test]
    fn leaves_a_well_exposed_image_alone() {
        assert_eq!(auto_exposure(8_000.0, 2.0).observe(108.0), None);
    }

    #[test]
    fn a_dark_image_raises_exposure_before_gain() {
        let mut ae = auto_exposure(4_000.0, 1.0);
        let (exposure_us, gain) = ae.observe(20.0).unwrap();
        assert!(exposure_us > 4_000.0);
        assert_eq!(gain, 1.0);
    }

    #[test]
    fn past_the_exposure_cap_it_raises_gain() {
        let mut ae = auto_exposure(20_000.0, 2.0);
        let (exposure_us, gain) = ae.observe(20.0).unwrap();
        assert_eq!(exposure_us, 20_000.0);
        assert!(gain > 2.0);
    }

    #[test]
    fn a_bright_image_lowers_gain_before_exposure() {
        let mut ae = auto_exposure(20_000.0, 4.0);
        let (exposure_us, gain) = ae.observe(250.0).unwrap();
        assert!(gain < 4.0);
        assert_eq!(exposure_us, 20_000.0);
    }

    #[test]
    fn steps_are_bounded() {
        let mut ae = auto_exposure(8_000.0, 2.0);
        let (exposure_us, gain) = ae.observe(1.0).unwrap();
        assert!(exposure_us * gain <= 2.0 * 8_000.0 * 2.0 + 1.0);
    }

    #[test]
    fn mean_samples_the_image() {
        assert_eq!(mean(&[10, 20, 30, 40], 1), 25.0);
        assert_eq!(mean(&[], 4), 0.0);
    }
}
