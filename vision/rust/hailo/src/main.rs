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
//!   channels (1 gray, 3 RGB), pixels, or u8 tag 3, u32 sequence, a JPEG; answered with the boxes, in the request's pixel
//!   coordinates, the HEF carrying its NMS in-graph.
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

use std::process::exit;

use framing::{log_record, LogLevel, Writer};

/// The longest request taken: above any camera's whole RGB frame.
#[cfg_attr(not(feature = "device"), allow(dead_code))]
const MAX_REQUEST_BYTES: usize = 64 << 20;

/// What a network makes of a request.
#[cfg_attr(not(feature = "device"), allow(dead_code))]
pub enum Answer {
    /// Not a request of the network's kind: there is no sequence to answer.
    Nothing,
    Reply(Vec<u8>),
    /// The network's vstreams may hold a frame: the program restarts after replying.
    ReplyThenExit(Vec<u8>),
}

/// The tag of every reply, before its network's index.
#[cfg(feature = "device")]
const REPLY_TAG: u8 = 10;

/// A LOG record, which `VisionCore.Hailo` hands to the Logger.
fn log(writer: &Writer, level: LogLevel, message: &str) {
    let _ = writer.write_record(&log_record(level, message));
}

/// A failure before stdout carries records goes to stderr.
fn exit_early(message: &str, status: i32) -> ! {
    eprintln!("hailo: {message}");
    exit(status)
}

fn main() {
    let command_line: Vec<String> = std::env::args().skip(1).collect();
    let networks = match arguments::parse(&command_line) {
        Ok(networks) => networks,
        Err(message) => exit_early(&format!("{message}\n{}", arguments::USAGE), 2),
    };

    // Before any HailoRT call: libhailort may log onto stdout.
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(error) => exit_early(&format!("stdout: {error}"), 1),
    };
    writer.log_panics();

    #[cfg(feature = "device")]
    exit(run(networks, writer));

    #[cfg(not(feature = "device"))]
    {
        let _ = networks;
        log(&writer, LogLevel::Error, "built without the device feature");
        exit(1);
    }
}

#[cfg(feature = "device")]
fn run(networks: Vec<arguments::Network>, writer: Writer) -> i32 {
    use std::sync::mpsc::{channel, Sender};
    use std::sync::Arc;
    use std::thread;

    use arguments::Kind;

    /// A network on its thread.
    trait Lane: Send {
        fn answer(&mut self, request: &[u8], writer: &Writer) -> Answer;
        fn description(&self) -> String;
    }

    impl Lane for detect::Detect {
        fn answer(&mut self, request: &[u8], writer: &Writer) -> Answer {
            detect::Detect::answer(self, request, writer)
        }
        fn description(&self) -> String {
            format!("detection {}", detect::Detect::description(self))
        }
    }

    impl Lane for segment::Segment {
        fn answer(&mut self, request: &[u8], writer: &Writer) -> Answer {
            segment::Segment::answer(self, request, writer)
        }
        fn description(&self) -> String {
            format!("segmentation {}", segment::Segment::description(self))
        }
    }

    let writer = Arc::new(writer);
    let opened = hailo::Device::open().and_then(|device| {
        let jpegs = jpeg::SharedDecoder::new()?;
        networks
            .iter()
            .map(|network| -> Result<Box<dyn Lane>, String> {
                Ok(match network.kind {
                    Kind::Detection { score_threshold } => Box::new(detect::Detect::open(
                        &device,
                        &network.hef_path,
                        score_threshold,
                        &jpegs,
                    )?),
                    Kind::Segmentation { cell_pixels } => Box::new(segment::Segment::open(
                        &device,
                        &network.hef_path,
                        cell_pixels,
                        &jpegs,
                    )?),
                })
            })
            .collect::<Result<Vec<_>, String>>()
    });
    let lanes = match opened {
        Ok(lanes) => lanes,
        Err(message) => {
            log(&writer, LogLevel::Error, &message);
            return 1;
        }
    };

    // Each network answers on its own thread; one that must restart takes the program with it.
    let senders: Vec<Sender<Vec<u8>>> = lanes
        .into_iter()
        .enumerate()
        .map(|(index, mut lane)| {
            log(
                &writer,
                LogLevel::Info,
                &format!("network {index} ready: {}", lane.description()),
            );
            let (sender, receiver) = channel::<Vec<u8>>();
            let writer = Arc::clone(&writer);
            let prefix = [REPLY_TAG, index as u8];
            thread::spawn(move || {
                for request in receiver {
                    let (reply, then_exit) = match lane.answer(&request, &writer) {
                        Answer::Nothing => continue,
                        Answer::Reply(reply) => (reply, false),
                        Answer::ReplyThenExit(reply) => (reply, true),
                    };
                    if writer.write_record_parts(&[&prefix, &reply]).is_err() {
                        exit(0);
                    }
                    if then_exit {
                        exit(1);
                    }
                }
            });
            sender
        })
        .collect();

    let mut stdin = std::io::stdin().lock();
    while let Ok(Some(mut record)) = framing::read_record(&mut stdin, MAX_REQUEST_BYTES) {
        let Some(&index) = record.first() else {
            continue;
        };
        match senders.get(usize::from(index)) {
            Some(sender) => {
                record.remove(0);
                if sender.send(record).is_err() {
                    return 1;
                }
            }
            None => log(
                &writer,
                LogLevel::Warning,
                &format!("a request for network {index}, which this program does not run; skipped"),
            ),
        }
    }
    0
}
