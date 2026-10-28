//! What to answer for a frame, given how its inference went.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameOutcome {
    Inferred,
    /// Nothing was queued. `streams_cleared`: the vstreams were emptied afterwards.
    WriteFailed {
        streams_cleared: bool,
    },
    /// The frame was queued and may still be in flight on the device.
    ReadFailed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reply {
    Detections,
    Empty,
    /// A frame left in the vstreams would answer the next request, so the process
    /// exits and its supervisor restarts it with fresh vstreams.
    EmptyThenExit,
}

pub fn reply_for(outcome: FrameOutcome) -> Reply {
    match outcome {
        FrameOutcome::Inferred => Reply::Detections,
        FrameOutcome::WriteFailed {
            streams_cleared: true,
        } => Reply::Empty,
        FrameOutcome::WriteFailed {
            streams_cleared: false,
        }
        | FrameOutcome::ReadFailed => Reply::EmptyThenExit,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inferred_frame_answers_detections() {
        assert_eq!(reply_for(FrameOutcome::Inferred), Reply::Detections);
    }

    #[test]
    fn write_failure_with_cleared_streams_answers_empty_and_continues() {
        let outcome = FrameOutcome::WriteFailed {
            streams_cleared: true,
        };
        assert_eq!(reply_for(outcome), Reply::Empty);
    }

    #[test]
    fn write_failure_without_cleared_streams_answers_empty_and_exits() {
        let outcome = FrameOutcome::WriteFailed {
            streams_cleared: false,
        };
        assert_eq!(reply_for(outcome), Reply::EmptyThenExit);
    }

    #[test]
    fn read_failure_answers_empty_and_exits() {
        assert_eq!(reply_for(FrameOutcome::ReadFailed), Reply::EmptyThenExit);
    }
}
