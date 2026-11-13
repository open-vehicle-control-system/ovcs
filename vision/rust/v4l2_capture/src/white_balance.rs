//! White balance: the gains that bring red and blue to green's level.

/// Red's and blue's gains relative to green's.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Gains {
    pub red: f64,
    pub blue: f64,
}

pub const MIN_GAIN: f64 = 0.5;
pub const MAX_GAIN: f64 = 4.0;
/// Below this mean green signal, in raw sample units, a frame is too dark to
/// say what colour its light is.
const MIN_GREEN: f64 = 1.0;

/// The grey-world gains for a frame whose mean red, green and blue above the
/// black level are `means`: those that make the frame's mean grey, each
/// within `MIN_GAIN..=MAX_GAIN`. A frame too dark to measure keeps `current`.
pub fn grey_world([red, green, blue]: [f64; 3], current: Gains) -> Gains {
    if green < MIN_GREEN {
        return current;
    }
    let gain = |mean: f64| (green / mean.max(f64::MIN_POSITIVE)).clamp(MIN_GAIN, MAX_GAIN);
    Gains {
        red: gain(red),
        blue: gain(blue),
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
    fn a_black_frame_keeps_the_gains_it_had() {
        assert_eq!(grey_world([0.0, 0.0, 0.0], KEPT), KEPT);
        assert_eq!(grey_world([3.0, 0.5, 0.0], KEPT), KEPT);
    }
}
