//! White balance: the gains that bring red and blue to green's level.

/// Red's and blue's gains relative to green's.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Gains {
    pub red: f64,
    pub blue: f64,
}

pub const MIN_GAIN: f64 = 0.5;
pub const MAX_GAIN: f64 = 4.0;
/// A gain holds while the grey-world one stays within this share of it, so
/// that a still scene's noise leaves the gains as they are.
const GAIN_DEADBAND: f64 = 0.005;
/// Below this mean green signal, in raw sample units, a frame is too dark to
/// say what colour its light is.
const MIN_GREEN: f64 = 1.0;

/// The grey-world gains for a frame whose mean red, green and blue above the
/// black level are `means`: those that make the frame's mean grey, each
/// within `MIN_GAIN..=MAX_GAIN`, each of `current` kept while within
/// `GAIN_DEADBAND` of them. A frame too dark to measure keeps `current`.
pub fn grey_world([red, green, blue]: [f64; 3], current: Gains) -> Gains {
    if green < MIN_GREEN {
        return current;
    }
    let gain = |mean: f64, current: f64| {
        let gain = (green / mean.max(f64::MIN_POSITIVE)).clamp(MIN_GAIN, MAX_GAIN);
        if (gain / current - 1.0).abs() <= GAIN_DEADBAND {
            current
        } else {
            gain
        }
    };
    Gains {
        red: gain(red, current.red),
        blue: gain(blue, current.blue),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEPT: Gains = Gains {
        red: 1.8,
        blue: 1.4,
    };

    #[test]
    fn grey_world_brings_the_mean_red_and_blue_to_the_mean_green() {
        assert_eq!(
            grey_world([100.0, 200.0, 400.0], KEPT),
            Gains {
                red: 2.0,
                blue: 0.5
            }
        );
    }

    #[test]
    fn gains_are_clamped_for_a_scene_missing_a_colour() {
        assert_eq!(
            grey_world([0.0, 200.0, 2_000.0], KEPT),
            Gains {
                red: 4.0,
                blue: 0.5
            }
        );
        assert_eq!(
            grey_world([2_000.0, 200.0, 1.0], KEPT),
            Gains {
                red: 0.5,
                blue: 4.0
            }
        );
    }

    #[test]
    fn a_gain_holds_until_the_scene_moves_it_by_more_than_the_deadband() {
        let current = Gains {
            red: 2.0,
            blue: 0.5,
        };
        let within = 1.0 + GAIN_DEADBAND / 2.0;
        let beyond = 1.0 + GAIN_DEADBAND * 2.0;
        assert_eq!(
            grey_world([100.0 / within, 200.0, 400.0 * within], current),
            current
        );
        let moved = grey_world([100.0 / beyond, 200.0, 400.0], current);
        assert!((moved.red - 2.0 * beyond).abs() < 1e-12, "{moved:?}");
        assert_eq!(moved.blue, 0.5);
    }

    #[test]
    fn a_black_frame_keeps_the_gains_it_had() {
        assert_eq!(grey_world([0.0, 0.0, 0.0], KEPT), KEPT);
        assert_eq!(grey_world([3.0, 0.5, 0.0], KEPT), KEPT);
    }
}
