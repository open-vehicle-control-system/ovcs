//! Automatic exposure for sensors without an ISP to run one.

use std::io;

use crate::settings::Settings;

/// A sensor's exposure time and analogue gain.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Exposure {
    pub exposure_us: f64,
    pub gain: f64,
}

/// Steers the mean grey of the image to `target` by changing the exposure
/// time first, up to `max_exposure_us`, then the analogue gain, up to
/// `max_gain`. Brightness is gamma-encoded, so the light needed scales with
/// the brightness ratio to the power `gamma`; each step at most doubles or
/// halves it, against oscillation while the sensor applies the last one.
/// The caps hold at every step, the image close to its target or not.
pub struct AutoExposure {
    pub exposure: Exposure,
    pub max_exposure_us: f64,
    pub max_gain: f64,
    pub target: f64,
    pub gamma: f64,
}

const MIN_EXPOSURE_US: f64 = 100.0;
const DEADBAND: f64 = 0.08;

impl AutoExposure {
    /// The new exposure for an image of mean grey `mean`, or `None` when it
    /// is close enough to the target and within the caps.
    pub fn observe(&mut self, mean: f64) -> Option<Exposure> {
        let ratio = self.target / mean.max(1.0);
        if (ratio - 1.0).abs() < DEADBAND {
            return self.capped();
        }
        self.step_to(self.light() * ratio.powf(self.gamma).clamp(0.5, 2.0))
    }

    /// The exposure and gain brought within the caps, the light kept as far
    /// as they allow, or `None` when both already are.
    pub fn capped(&mut self) -> Option<Exposure> {
        let Exposure { exposure_us, gain } = self.exposure;
        if exposure_us <= self.max_exposure_us && gain <= self.max_gain {
            return None;
        }
        self.step_to(self.light())
    }

    /// The light the running exposure lets in: its time by its gain.
    fn light(&self) -> f64 {
        self.exposure.exposure_us * self.exposure.gain
    }

    /// Exposure then gain for `light`, their product, within the caps.
    fn step_to(&mut self, light: f64) -> Option<Exposure> {
        let light = light.clamp(MIN_EXPOSURE_US, self.max_exposure_us * self.max_gain);
        let exposure_us = light.min(self.max_exposure_us);
        let gain = (light / exposure_us).clamp(1.0, self.max_gain);
        let exposure = Exposure { exposure_us, gain };
        if exposure == self.exposure {
            return None;
        }
        self.exposure = exposure;
        Some(exposure)
    }
}

pub fn auto_exposure(settings: &Settings, frame_us: f64) -> AutoExposure {
    auto_exposure_from(settings, frame_us, settings.manual_exposure())
}

/// Where auto exposure continues from after a settings change: where it ran,
/// or, while it is off, the manual values `apply_manual` gives the sensors,
/// so switching it on again starts from what they hold.
pub fn resume_point(
    settings: &Settings,
    running: Exposure,
    apply_manual: impl FnOnce() -> io::Result<Exposure>,
) -> io::Result<Exposure> {
    if settings.auto_exposure {
        Ok(running)
    } else {
        apply_manual()
    }
}

/// Auto exposure from `settings`, continuing from `exposure`.
pub fn auto_exposure_from(settings: &Settings, frame_us: f64, exposure: Exposure) -> AutoExposure {
    AutoExposure {
        exposure,
        max_exposure_us: f64::from(settings.max_exposure_us).min(frame_us),
        max_gain: settings.max_gain,
        target: settings.target_brightness,
        gamma: settings.gamma,
    }
}

/// The exposure and gain auto exposure, while on, applies at once to stay
/// within caps a settings change lowered.
pub fn capped_now(settings: &Settings, auto_exposure: &mut AutoExposure) -> Option<Exposure> {
    if settings.auto_exposure {
        auto_exposure.capped()
    } else {
        None
    }
}

/// Mean of every `stride`-th byte of `image`.
pub fn mean(image: &[u8], stride: usize) -> f64 {
    let (sum, count) = image
        .iter()
        .step_by(stride.max(1))
        .fold((0u64, 0u64), |(sum, count), sample| {
            (sum + u64::from(*sample), count + 1)
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
            exposure: Exposure { exposure_us, gain },
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
        let mut auto_exposure = auto_exposure(4_000.0, 1.0);
        let Exposure { exposure_us, gain } = auto_exposure.observe(20.0).unwrap();
        assert!(exposure_us > 4_000.0);
        assert_eq!(gain, 1.0);
    }

    #[test]
    fn past_the_exposure_cap_it_raises_gain() {
        let mut auto_exposure = auto_exposure(20_000.0, 2.0);
        let Exposure { exposure_us, gain } = auto_exposure.observe(20.0).unwrap();
        assert_eq!(exposure_us, 20_000.0);
        assert!(gain > 2.0);
    }

    #[test]
    fn a_bright_image_lowers_gain_before_exposure() {
        let mut auto_exposure = auto_exposure(20_000.0, 4.0);
        let Exposure { exposure_us, gain } = auto_exposure.observe(250.0).unwrap();
        assert!(gain < 4.0);
        assert_eq!(exposure_us, 20_000.0);
    }

    #[test]
    fn a_lowered_exposure_cap_holds_on_a_well_exposed_image() {
        let mut auto_exposure = auto_exposure(20_000.0, 2.0);
        auto_exposure.max_exposure_us = 5_000.0;
        assert_eq!(
            auto_exposure.observe(110.0),
            Some(Exposure {
                exposure_us: 5_000.0,
                gain: 8.0
            })
        );
    }

    #[test]
    fn a_lowered_gain_cap_holds_on_a_well_exposed_image() {
        let mut auto_exposure = auto_exposure(20_000.0, 10.0);
        auto_exposure.max_gain = 4.0;
        assert_eq!(
            auto_exposure.observe(110.0),
            Some(Exposure {
                exposure_us: 20_000.0,
                gain: 4.0
            })
        );
    }

    #[test]
    fn a_raised_cap_leaves_a_well_exposed_image_alone() {
        let mut auto_exposure = auto_exposure(10_000.0, 4.0);
        auto_exposure.max_exposure_us = 40_000.0;
        auto_exposure.max_gain = 16.0;
        assert_eq!(auto_exposure.observe(110.0), None);
    }

    #[test]
    fn capped_brings_the_running_values_within_lowered_caps() {
        let mut auto_exposure = auto_exposure(20_000.0, 2.0);
        auto_exposure.max_exposure_us = 5_000.0;
        auto_exposure.max_gain = 4.0;
        let capped = Exposure {
            exposure_us: 5_000.0,
            gain: 4.0,
        };
        assert_eq!(auto_exposure.capped(), Some(capped));
        assert_eq!(auto_exposure.exposure, capped);
        assert_eq!(auto_exposure.capped(), None);
    }

    #[test]
    fn steps_are_bounded() {
        let mut auto_exposure = auto_exposure(8_000.0, 2.0);
        let Exposure { exposure_us, gain } = auto_exposure.observe(1.0).unwrap();
        assert!(exposure_us * gain <= 2.0 * 8_000.0 * 2.0 + 1.0);
    }

    #[test]
    fn mean_samples_the_image() {
        assert_eq!(mean(&[10, 20, 30, 40], 1), 25.0);
        assert_eq!(mean(&[], 4), 0.0);
    }

    #[test]
    fn auto_exposure_switched_on_again_starts_from_the_manual_values() {
        let mut settings = Settings::default();
        let start = Exposure {
            exposure_us: 12_000.0,
            gain: 3.0,
        };
        let mut auto_exposure = auto_exposure_from(&settings, 33_333.0, start);

        settings.apply(b"auto_exposure=false").unwrap();
        settings.apply(b"exposure_us=5000").unwrap();
        let manual = Exposure {
            exposure_us: 5_000.0,
            gain: 1.5,
        };
        let resume_from = resume_point(&settings, auto_exposure.exposure, || Ok(manual)).unwrap();
        auto_exposure = auto_exposure_from(&settings, 33_333.0, resume_from);

        settings.apply(b"auto_exposure=true").unwrap();
        let resume_from = resume_point(&settings, auto_exposure.exposure, || {
            panic!("no manual values while automatic")
        })
        .unwrap();
        assert_eq!(resume_from, manual);
    }

    #[test]
    fn lowered_caps_apply_at_once_to_auto_exposure_and_never_to_manual_values() {
        let mut settings = Settings::default();
        settings.apply(b"auto_exposure=false").unwrap();
        settings.apply(b"max_exposure_us=1000").unwrap();
        let start = Exposure {
            exposure_us: 8_000.0,
            gain: 2.0,
        };
        let mut auto_exposure = auto_exposure_from(&settings, 33_333.0, start);
        assert_eq!(capped_now(&settings, &mut auto_exposure), None);

        settings.apply(b"auto_exposure=true").unwrap();
        assert_eq!(
            capped_now(&settings, &mut auto_exposure),
            Some(Exposure {
                exposure_us: 1_000.0,
                gain: 16.0
            })
        );
    }
}
