//! Cancelled requests in a row, told apart from a pipeline that has stopped.

/// Counts the requests libcamera cancels while the camera runs. A request it
/// cancels is queued again, but once every request in flight came back
/// cancelled with no frame between, the pipeline has stopped: libcamera
/// still accepts a request it can no longer run, and cancels it again.
pub struct Cancellations {
    in_a_row: usize,
    requests: usize,
}

impl Cancellations {
    pub fn new(requests: usize) -> Cancellations {
        Cancellations {
            in_a_row: 0,
            requests,
        }
    }

    /// Notes a cancelled request: `false` once the pipeline has stopped.
    pub fn cancelled(&mut self) -> bool {
        self.in_a_row += 1;
        self.in_a_row < self.requests
    }

    /// Notes a completed request.
    pub fn completed(&mut self) {
        self.in_a_row = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cancelled_request_is_queued_again_while_others_complete() {
        let mut cancellations = Cancellations::new(4);
        for _ in 0..10 {
            assert!(cancellations.cancelled());
            assert!(cancellations.cancelled());
            cancellations.completed();
        }
    }

    #[test]
    fn every_request_cancelled_in_a_row_stops_the_capture() {
        let mut cancellations = Cancellations::new(4);
        for _ in 0..3 {
            assert!(cancellations.cancelled());
        }
        assert!(!cancellations.cancelled());
    }
}
