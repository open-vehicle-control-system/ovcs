//! The time a Port's requests spend in each of its stages, averaged and logged as one line a
//! period.

use std::time::{Duration, Instant};

/// How often a Port logs its stage times.
pub const STAGE_TIMES_EVERY: Duration = Duration::from_secs(60);

struct Stage {
    name: &'static str,
    total_micros: u64,
    samples: u64,
}

/// Each stage's time over the requests answered since the last line.
pub struct StageTimes {
    stages: Vec<Stage>,
    every: Duration,
    since: Instant,
    requests: u64,
}

impl StageTimes {
    /// Stage times for the stages `names`, in the order the line gives them, one line every
    /// `every` from `now`.
    pub fn new(names: &[&'static str], every: Duration, now: Instant) -> StageTimes {
        StageTimes {
            stages: names
                .iter()
                .map(|&name| Stage {
                    name,
                    total_micros: 0,
                    samples: 0,
                })
                .collect(),
            every,
            since: now,
            requests: 0,
        }
    }

    /// Adds one sample of `micros` to the stage `name`, which must be one of `new`'s.
    pub fn add(&mut self, name: &str, micros: u64) {
        let stage = self
            .stages
            .iter_mut()
            .find(|stage| stage.name == name)
            .unwrap_or_else(|| panic!("no stage {name}"));
        stage.total_micros = stage.total_micros.saturating_add(micros);
        stage.samples += 1;
    }

    /// Adds the time from `mark` to now to the stage `name`, and moves `mark` to now.
    pub fn lap(&mut self, name: &str, mark: &mut Instant) {
        let now = Instant::now();
        self.add(name, micros(now - *mark));
        *mark = now;
    }

    /// Counts one request answered.
    pub fn count_request(&mut self) {
        self.requests += 1;
    }

    /// The line to log once `every` has passed since the last one, the times then starting
    /// over: the requests answered and each stage's mean time in µs, followed by its sample
    /// count when it timed fewer requests.
    pub fn line(&mut self, now: Instant) -> Option<String> {
        let elapsed = now.saturating_duration_since(self.since);
        if elapsed < self.every {
            return None;
        }
        let stages: Vec<String> = self
            .stages
            .iter()
            .map(|stage| match stage.samples {
                0 => format!("{} none", stage.name),
                samples if samples == self.requests => {
                    format!("{} {}", stage.name, stage.total_micros / samples)
                }
                samples => format!(
                    "{} {} ({samples} timed)",
                    stage.name,
                    stage.total_micros / samples
                ),
            })
            .collect();
        let line = format!(
            "last {} s: {} requests, us each: {}",
            elapsed.as_secs(),
            self.requests,
            stages.join(", ")
        );
        for stage in &mut self.stages {
            (stage.total_micros, stage.samples) = (0, 0);
        }
        self.requests = 0;
        self.since = now;
        Some(line)
    }
}

/// `duration` in whole µs, saturated.
pub fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    const EVERY: Duration = Duration::from_secs(60);

    #[test]
    fn no_line_before_the_period_has_passed() {
        let start = Instant::now();
        let mut times = StageTimes::new(&["read"], EVERY, start);
        times.add("read", 10);
        times.count_request();
        assert_eq!(times.line(start + Duration::from_secs(59)), None);
    }

    #[test]
    fn the_line_gives_the_requests_and_each_stages_mean_in_order() {
        let start = Instant::now();
        let mut times = StageTimes::new(&["read", "letterbox", "reply"], EVERY, start);
        for (read, letterbox, reply) in [(1000, 15_000, 40), (3000, 17_001, 60)] {
            times.add("reply", reply);
            times.add("read", read);
            times.add("letterbox", letterbox);
            times.count_request();
        }
        assert_eq!(
            times.line(start + Duration::from_secs(61)).as_deref(),
            Some("last 61 s: 2 requests, us each: read 2000, letterbox 16000, reply 50")
        );
    }

    #[test]
    fn a_stage_timing_fewer_requests_says_how_many() {
        let start = Instant::now();
        let mut times = StageTimes::new(&["graphExecute", "HTP", "host RPC"], EVERY, start);
        for htp in [Some(8000), None, Some(9000)] {
            times.add("graphExecute", 20_000);
            if let Some(htp) = htp {
                times.add("HTP", htp);
            }
            times.count_request();
        }
        assert_eq!(
            times.line(start + EVERY).as_deref(),
            Some(
                "last 60 s: 3 requests, us each: graphExecute 20000, HTP 8500 (2 timed), \
                 host RPC none"
            )
        );
    }

    #[test]
    fn the_times_start_over_after_each_line() {
        let start = Instant::now();
        let mut times = StageTimes::new(&["read"], EVERY, start);
        times.add("read", 10);
        times.count_request();
        let first = start + EVERY;
        assert!(times.line(first).is_some());
        assert_eq!(times.line(first + Duration::from_secs(1)), None);
        times.add("read", 30);
        times.count_request();
        assert_eq!(
            times.line(first + EVERY).as_deref(),
            Some("last 60 s: 1 requests, us each: read 30")
        );
    }

    #[test]
    #[should_panic(expected = "no stage decode")]
    fn a_stage_not_named_at_the_start_is_a_bug() {
        StageTimes::new(&["read"], EVERY, Instant::now()).add("decode", 1);
    }
}
