//! The libcamera streams a capture asks for: the frames' own and, with an ISP
//! output, a second one beside it in the same request.

use crate::arguments::{Arguments, OutputSpec};

/// libcamera's role of a stream, which picks its defaults.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    VideoRecording,
    ViewFinder,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stream {
    pub role: Role,
    pub width: u32,
    pub height: u32,
}

/// The streams in the order libcamera is given them, and which is which.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamPlan {
    pub streams: Vec<Stream>,
    /// The index of the stream the FRAME or GREY_FRAME records are made from.
    pub frames: usize,
    /// The index of the ISP output's stream.
    pub isp_output: Option<usize>,
}

/// The streams of `arguments`. The ISP output comes first, the frames' stream
/// second as the view finder: the order the Pi 5's PiSP pipeline is known to
/// take for an ISP output larger than the frames.
pub fn plan(arguments: &Arguments) -> StreamPlan {
    let frames = |role| Stream {
        role,
        width: arguments.width,
        height: arguments.height,
    };
    let isp_output = arguments.outputs.iter().find_map(|spec| match *spec {
        OutputSpec::Isp { width, height } => Some(Stream {
            role: Role::VideoRecording,
            width,
            height,
        }),
        OutputSpec::Jpeg { .. } => None,
    });
    match isp_output {
        None => StreamPlan {
            streams: vec![frames(Role::VideoRecording)],
            frames: 0,
            isp_output: None,
        },
        Some(isp_output) => StreamPlan {
            streams: vec![isp_output, frames(Role::ViewFinder)],
            frames: 1,
            isp_output: Some(0),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arguments::parse;

    fn plan_of(command_line: &[&str]) -> StreamPlan {
        let command_line: Vec<String> = command_line.iter().map(|a| a.to_string()).collect();
        plan(&parse(&command_line).unwrap())
    }

    #[test]
    fn without_outputs_the_frames_are_the_one_video_recording_stream() {
        assert_eq!(
            plan_of(&["--width", "480", "--height", "270", "--format", "grey"]),
            StreamPlan {
                streams: vec![Stream {
                    role: Role::VideoRecording,
                    width: 480,
                    height: 270
                }],
                frames: 0,
                isp_output: None,
            }
        );
    }

    #[test]
    fn an_isp_output_is_the_video_recording_stream_before_the_frames_view_finder() {
        assert_eq!(
            plan_of(&[
                "--width",
                "480",
                "--height",
                "270",
                "--format",
                "grey",
                "--output",
                "isp:1152x648:unsent",
                "--output",
                "from:0:1152x648:jpeg:80"
            ]),
            StreamPlan {
                streams: vec![
                    Stream {
                        role: Role::VideoRecording,
                        width: 1152,
                        height: 648
                    },
                    Stream {
                        role: Role::ViewFinder,
                        width: 480,
                        height: 270
                    }
                ],
                frames: 1,
                isp_output: Some(0),
            }
        );
    }
}
