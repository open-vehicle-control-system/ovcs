//! The log lines saying what an execution's time measures.

use crate::TimeSource;

/// What the inference times in the replies measure, logged at the first execution,
/// when the profile is lost, and when the count of executions the profile did not
/// time reaches a power of two.
#[derive(Debug, Default)]
pub struct TimeLog {
    first_logged: bool,
    profile_loss_logged: bool,
    untimed: u64,
}

impl TimeLog {
    /// The message to log for an execution timed by `source`, if any.
    /// `profile_error` is why the profile is gone, if it is.
    pub fn message(&mut self, source: TimeSource, profile_error: Option<&str>) -> Option<String> {
        let first = !std::mem::replace(&mut self.first_logged, true);
        match (source, profile_error) {
            (TimeSource::Accelerator, _) => first.then(|| {
                "inference time: the HTP's execution time, from QNN's profile".to_string()
            }),
            (TimeSource::WallTime, Some(error)) => {
                (!std::mem::replace(&mut self.profile_loss_logged, true)).then(|| {
                    format!(
                        "inference time: the wall time around graphExecute, no profile: {error}"
                    )
                })
            }
            (TimeSource::WallTime, None) => {
                self.untimed += 1;
                self.untimed.is_power_of_two().then(|| {
                    let executions = match self.untimed {
                        1 => "1 execution".to_string(),
                        count => format!("{count} executions"),
                    };
                    format!(
                        "inference time: {executions} timed by the wall time around \
                         graphExecute, the profile reporting no accelerator time"
                    )
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ERROR: &str = "profileCreate failed with QNN error 1";

    fn messages(sources: &[(TimeSource, Option<&str>)]) -> Vec<Option<String>> {
        let mut time_log = TimeLog::default();
        sources
            .iter()
            .map(|&(source, error)| time_log.message(source, error))
            .collect()
    }

    #[test]
    fn the_first_source_is_logged_once() {
        let logged = messages(&[(TimeSource::Accelerator, None); 3]);
        assert!(logged[0].as_deref().unwrap().contains("QNN's profile"));
        assert_eq!(logged[1..], [None, None]);
    }

    #[test]
    fn the_loss_of_the_profile_is_logged_once() {
        let logged = messages(&[
            (TimeSource::Accelerator, None),
            (TimeSource::WallTime, Some(ERROR)),
            (TimeSource::WallTime, Some(ERROR)),
        ]);
        assert!(logged[1].as_deref().unwrap().contains(ERROR));
        assert_eq!(logged[2], None);

        let logged = messages(&[(TimeSource::WallTime, Some(ERROR)); 2]);
        assert!(logged[0].as_deref().unwrap().contains(ERROR));
        assert_eq!(logged[1], None);
    }

    #[test]
    fn executions_the_profile_did_not_time_are_logged_at_powers_of_two() {
        let mut sources = vec![(TimeSource::Accelerator, None)];
        sources.extend(
            [
                (TimeSource::WallTime, None),
                (TimeSource::Accelerator, None),
            ]
            .repeat(4),
        );
        let logged: Vec<_> = messages(&sources).into_iter().skip(1).flatten().collect();
        assert_eq!(logged.len(), 3);
        assert!(logged[0].starts_with("inference time: 1 execution"));
        assert!(logged[1].starts_with("inference time: 2 executions"));
        assert!(logged[2].starts_with("inference time: 4 executions"));
    }
}
