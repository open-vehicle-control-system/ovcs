//! Which frames the outputs are made on, at most `--outputs-max-hz` a second.
//!
//! The frames taken are kept on a schedule of capture times `1 / max_hz` s
//! apart, a frame due within three quarters of a frame period of its slot,
//! so that a rate below the camera's holds whatever the capture times'
//! jitter. A frame later than that, or captured before the last one taken,
//! as when the clock starts over, starts the schedule over from its own
//! capture time.

const NS_PER_S: f64 = 1e9;

/// The lowest `max_hz` above 0: its interval and a capture time, each at most
/// half of `i64::MAX`, add up without overflowing.
pub const MIN_MAX_HZ: f64 = NS_PER_S / (i64::MAX / 2) as f64;

pub struct Schedule {
    /// `None` takes every frame.
    interval_ns: Option<i64>,
    slack_ns: i64,
    next_due_ns: Option<i64>,
}

impl Schedule {
    /// At most `max_hz` frames a second, 0 for every frame or from
    /// `MIN_MAX_HZ`, of a camera at `fps`.
    pub fn new(max_hz: f64, fps: u32) -> Schedule {
        Schedule {
            interval_ns: (max_hz > 0.0).then(|| (NS_PER_S / max_hz).round() as i64),
            slack_ns: 3 * 1_000_000_000 / (4 * i64::from(fps.max(1))),
            next_due_ns: None,
        }
    }

    /// Whether the frame captured at `capture_ns` is due, which moves the
    /// schedule on to the next slot when it is.
    pub fn take_if_due(&mut self, capture_ns: i64) -> bool {
        let Some(interval_ns) = self.interval_ns else {
            return true;
        };
        if self.too_soon(capture_ns, interval_ns) {
            return false;
        }
        let slot_ns = match self.next_due_ns {
            Some(next_due_ns) if (capture_ns - next_due_ns).abs() <= self.slack_ns => next_due_ns,
            _ => capture_ns,
        };
        self.next_due_ns = Some(slot_ns + interval_ns);
        true
    }

    // Before its slot's slack, and not before the previous slot's, which only a clock that started over gives.
    fn too_soon(&self, capture_ns: i64, interval_ns: i64) -> bool {
        self.next_due_ns.is_some_and(|next_due_ns| {
            let due_from_ns = next_due_ns - self.slack_ns;
            capture_ns < due_from_ns && capture_ns >= due_from_ns - interval_ns
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME_PERIOD_NS: i64 = 1_000_000_000 / 30;

    // `count` capture times at 30 fps, each a few ms early or late, as capture times are.
    fn jittered_ns(count: i64) -> Vec<i64> {
        let jitter_ms = [0, 1, -2, 2, -1];
        (0..count)
            .map(|index| index * FRAME_PERIOD_NS + jitter_ms[index as usize % 5] * 1_000_000)
            .collect()
    }

    // 10 s of frames from a camera set to 30 fps that delivers 29.97, alternately 3 ms late and early.
    fn measured_rate_ns() -> Vec<i64> {
        (0..300)
            .map(|index| {
                index * 1_001_000_000 / 30 + if index % 2 == 0 { 3 } else { -3 } * 1_000_000
            })
            .collect()
    }

    fn taken_ns(max_hz: f64, captures_ns: &[i64]) -> Vec<i64> {
        let mut schedule = Schedule::new(max_hz, 30);
        (captures_ns.iter().copied())
            .filter(|capture_ns| schedule.take_if_due(*capture_ns))
            .collect()
    }

    #[test]
    fn at_half_the_cameras_rate_takes_every_other_frame_whatever_their_jitter() {
        let captures_ns = jittered_ns(12);
        let every_other: Vec<i64> = captures_ns.iter().copied().step_by(2).collect();
        assert_eq!(taken_ns(15.0, &captures_ns), every_other);
    }

    #[test]
    fn takes_max_hz_frames_a_second_of_the_cameras_29_97_whatever_their_jitter() {
        for (max_hz, tolerance) in [(10.0, 1), (15.0, 1), (20.0, 2), (25.0, 2)] {
            let taken = taken_ns(max_hz, &measured_rate_ns()).len() as i64;
            let expected = (max_hz * 10.0) as i64;
            assert!(
                (taken - expected).abs() <= tolerance,
                "{max_hz} Hz: {taken} frames in 10 s"
            );
        }
    }

    #[test]
    fn at_the_cameras_rate_or_0_takes_every_frame() {
        let captures_ns = measured_rate_ns();
        assert_eq!(taken_ns(30.0, &captures_ns), captures_ns);
        assert_eq!(taken_ns(0.0, &captures_ns), captures_ns);
    }

    #[test]
    fn starts_over_from_a_frame_captured_before_the_last_one_taken() {
        let [first, second, third, fourth] = jittered_ns(4)[..] else {
            unreachable!()
        };
        assert_eq!(
            taken_ns(15.0, &[1_000_000_000, first, second, third, fourth]),
            [1_000_000_000, first, third]
        );
    }

    #[test]
    fn starts_over_from_a_frame_later_than_its_slot() {
        let captures_ns = jittered_ns(12);
        let after_a_gap = [
            captures_ns[0],
            captures_ns[5],
            captures_ns[6],
            captures_ns[7],
        ];
        assert_eq!(
            taken_ns(15.0, &after_a_gap),
            [captures_ns[0], captures_ns[5], captures_ns[7]]
        );
    }
}
