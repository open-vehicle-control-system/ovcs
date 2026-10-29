//! Locks the right sensor's frame starts to the left sensor's by adjusting the
//! right sensor's vertical blanking.

use std::collections::VecDeque;

const GAIN: f64 = 0.5;
const DEADBAND_LINES: f64 = 2.0;
/// The lock counts as held while the median recent offset is below this.
const LOCKED_NS: i64 = 500_000;
/// While locked, a larger offset is taken for a late timestamp, not a phase
/// change, unless `OUTLIERS_TO_RELOCK` of them arrive in a row.
const OUTLIER_NS: i64 = 1_000_000;
const OUTLIERS_TO_RELOCK: u32 = 3;
const HISTORY: usize = 15;

pub struct PhaseLock {
    period_ns: i64,
    line_ns: f64,
    vblank0: i32,
    vblank_min: i32,
    vblank_max: i32,
    settling: bool,
    history: VecDeque<i64>,
    outliers: u32,
}

impl PhaseLock {
    pub fn new(
        period_ns: i64,
        line_ns: f64,
        vblank0: i32,
        vblank_min: i32,
        vblank_max: i32,
    ) -> PhaseLock {
        PhaseLock {
            period_ns,
            line_ns,
            vblank0,
            vblank_min,
            vblank_max,
            settling: false,
            history: VecDeque::with_capacity(HISTORY),
            outliers: 0,
        }
    }

    /// Takes the start times of the latest left and right frames and returns
    /// the right sensor's next VBLANK when it has to change. A correction lasts
    /// one frame: the call after it restores the nominal VBLANK, since a
    /// change only lands a frame or two after it is set.
    pub fn observe(&mut self, left_ns: i64, right_ns: i64) -> Option<i32> {
        if self.settling {
            self.settling = false;
            return Some(self.vblank0);
        }

        let offset = self.wrap(right_ns - left_ns);
        if self.locked() && offset.abs() > OUTLIER_NS {
            self.outliers += 1;
            if self.outliers < OUTLIERS_TO_RELOCK {
                return None;
            }
        }
        self.outliers = 0;
        if self.history.len() == HISTORY {
            self.history.pop_front();
        }
        self.history.push_back(offset.abs());

        if (offset.abs() as f64) <= DEADBAND_LINES * self.line_ns {
            return None;
        }
        let lines = (-GAIN * offset as f64 / self.line_ns).round() as i32;
        self.settling = true;
        Some((self.vblank0 + lines).clamp(self.vblank_min, self.vblank_max))
    }

    fn wrap(&self, offset: i64) -> i64 {
        let x = offset.rem_euclid(self.period_ns);
        if x > self.period_ns / 2 {
            x - self.period_ns
        } else {
            x
        }
    }

    fn locked(&self) -> bool {
        if self.history.len() < HISTORY {
            return false;
        }
        let mut recent: Vec<i64> = self.history.iter().copied().collect();
        recent.sort_unstable();
        recent[recent.len() / 2] < LOCKED_NS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PERIOD: i64 = 33_333_333;

    fn lock() -> PhaseLock {
        PhaseLock::new(PERIOD, 9_227.0, 2752, 40, 8_387_616)
    }

    #[test]
    fn leaves_the_sensor_alone_inside_the_deadband() {
        assert_eq!(lock().observe(0, 10_000), None);
    }

    #[test]
    fn shortens_a_late_right_frame_then_restores_it() {
        let mut l = lock();
        assert_eq!(l.observe(0, 1_000_000), Some(2752 - 54));
        assert_eq!(l.observe(0, 500_000), Some(2752));
    }

    #[test]
    fn wraps_the_offset_into_half_a_period() {
        assert_eq!(lock().observe(0, PERIOD - 1_000_000), Some(2752 + 54));
    }

    #[test]
    fn ignores_a_late_timestamp_while_locked_until_it_repeats() {
        let mut l = lock();
        for _ in 0..15 {
            assert_eq!(l.observe(0, 10_000), None);
        }
        assert_eq!(l.observe(0, 4_000_000), None);
        assert_eq!(l.observe(0, 4_000_000), None);
        assert_eq!(l.observe(0, 4_000_000), Some(2752 - 217));
    }

    #[test]
    fn clamps_to_the_sensor_range() {
        let mut l = PhaseLock::new(PERIOD, 9_227.0, 2752, 2700, 8_387_616);
        assert_eq!(l.observe(0, 1_000_000), Some(2700));
    }
}
