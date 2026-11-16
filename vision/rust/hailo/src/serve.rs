//! The networks opened on the device, each answering its requests on a thread of its own.

use std::process::exit;
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::thread;

use framing::{LogLevel, Writer};

use crate::arguments::{self, Kind};
use crate::{detect, hailo, jpeg, segment, Answer};

/// The tag of every reply, before its network's index.
const REPLY_TAG: u8 = 10;

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

pub fn run(networks: Vec<arguments::Network>, writer: Writer) -> i32 {
    let writer = Arc::new(writer);
    let lanes = match open_lanes(&networks) {
        Ok(lanes) => lanes,
        Err(message) => {
            writer.log(LogLevel::Error, &message);
            return 1;
        }
    };
    let senders: Vec<Sender<Vec<u8>>> = lanes
        .into_iter()
        .enumerate()
        .map(|(index, lane)| spawn_lane(index, lane, &writer))
        .collect();
    route_requests(&senders, &writer)
}

/// The device, and on it each network named, in order.
fn open_lanes(networks: &[arguments::Network]) -> Result<Vec<Box<dyn Lane>>, String> {
    let device = hailo::Device::open()?;
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
        .collect()
}

/// The sender of the requests for the network `index`, which `lane` answers on its own
/// thread; a lane that must restart takes the program with it.
fn spawn_lane(index: usize, mut lane: Box<dyn Lane>, writer: &Arc<Writer>) -> Sender<Vec<u8>> {
    writer.log(
        LogLevel::Info,
        &format!("network {index} ready: {}", lane.description()),
    );
    let (sender, receiver) = channel::<Vec<u8>>();
    let writer = Arc::clone(writer);
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
}

/// Hands each request to the lane of the network it names until the input closes; returns
/// the program's exit status.
fn route_requests(senders: &[Sender<Vec<u8>>], writer: &Writer) -> i32 {
    let mut requests = framing::Requests::new(std::io::stdin().lock(), framing::MAX_REQUEST_BYTES);
    loop {
        let record = match requests.read() {
            Ok(Some(record)) => record,
            Ok(None) => return 0,
            Err(error) => {
                writer.log(LogLevel::Error, &format!("reading a request: {error}"));
                return 1;
            }
        };
        let Some((&index, request)) = record.split_first() else {
            continue;
        };
        match senders.get(usize::from(index)) {
            Some(sender) => {
                if sender.send(request.to_vec()).is_err() {
                    return 1;
                }
            }
            None => writer.log(
                LogLevel::Warning,
                &format!("a request for network {index}, which this program does not run; skipped"),
            ),
        }
    }
}
