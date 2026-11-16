//! `hailo (--detect <model.hef> <score_threshold> | --segment <model.hef> <cell_pixels>)...`:
//! the Port behind `VisionCore.Hailo`. It opens the Hailo-8 once and configures on it each
//! network named, in order, as many as the device holds; HailoRT's scheduler gives them the
//! device in turn. Each network answers its requests one at a time, from a thread of its own,
//! so a long segmentation does not hold a detection back.
//!
//! A request is its network's index, a u8, then the request of the network's kind; a reply is
//! the tag 10, the network's index, then the reply of its kind:
//!
//! - detection (`detection::protocol`): u8 tag 1, u32 sequence, u16 width, u16 height, u8
//!   channels (1 grey, 3 RGB), pixels, or u8 tag 3, u32 sequence, a JPEG; answered with the
//!   boxes, in the request's pixel coordinates, the HEF carrying its NMS in-graph.
//! - segmentation (`segmentation::protocol`): u8 tag 7, an RGB image and a band of its rows,
//!   or u8 tag 8, a band and a JPEG;
//!   answered with a class id for each `cell_pixels` square cell of the band resized to the
//!   HEF's input, whose argmax is in-graph.
//!
//! Either reply carries, when the frame was inferred, its time in µs from the input's write
//! to the output's read; a request the program could not answer gets an empty one. LOG records
//! (`framing::log_record`) carry the program's log lines. Scalars are little-endian. A failed
//! read leaves a frame on the device that could answer the next request, so the program exits
//! for a restart.

mod arguments;
#[cfg(feature = "device")]
mod detect;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod direct;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod grid;
#[cfg(feature = "device")]
mod hailo;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod jpeg;
#[cfg_attr(not(feature = "device"), allow(dead_code))]
mod outcome;
#[cfg(feature = "device")]
mod segment;
#[cfg(feature = "device")]
mod serve;

use std::process::exit;

use framing::{exit_early, Writer};

const NAME: &str = "hailo";

/// What a network makes of a request.
#[cfg_attr(not(feature = "device"), allow(dead_code))]
pub enum Answer {
    /// Not a request of the network's kind: there is no sequence to answer.
    Nothing,
    Reply(Vec<u8>),
    /// The network's vstreams may hold a frame: the program restarts after replying.
    ReplyThenExit(Vec<u8>),
}

fn main() {
    let command_line: Vec<String> = std::env::args().skip(1).collect();
    let networks = match arguments::parse(&command_line) {
        Ok(networks) => networks,
        Err(message) => exit_early(NAME, &format!("{message}\n{}", arguments::USAGE), 2),
    };

    // Before any HailoRT call: libhailort may log onto stdout.
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(error) => exit_early(NAME, &format!("stdout: {error}"), 1),
    };
    writer.log_panics();

    #[cfg(feature = "device")]
    exit(serve::run(networks, writer));

    #[cfg(not(feature = "device"))]
    {
        let _ = networks;
        writer.log(framing::LogLevel::Error, "built without the device feature");
        exit(1);
    }
}
