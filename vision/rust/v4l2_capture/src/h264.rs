//! The outputs sent as H.264: each frame's NV12 image of each one, made on
//! the conversion threads (`plan`), encoded by the output's encoder on a
//! thread of its own while the writer writes the frame's other outputs.

use std::io;
use std::sync::{mpsc, Arc};

use crate::encoder::{EncodedFrame, Encoder};

/// What a frame's video encoders gave, one per H.264 output in their order,
/// with the handle on the frame's images they read.
pub struct EncodedVideo {
    pub frames: Vec<Option<EncodedFrame>>,
    pub images: Arc<Vec<Vec<u8>>>,
}

/// Encodes the image of each output of `outputs`, its index with its
/// encoder, of each frame `frames` brings with its capture time, and sends
/// what they give to `encoded`, until `frames` closes or nothing receives;
/// then stops the encoders.
pub fn encode_frames(
    outputs: &mut [(usize, Box<dyn Encoder>)],
    frames: mpsc::Receiver<(Arc<Vec<Vec<u8>>>, i64)>,
    encoded: mpsc::Sender<EncodedVideo>,
) -> io::Result<()> {
    for (images, capture_ns) in frames {
        let mut encoded_frames = Vec::with_capacity(outputs.len());
        for (index, encoder) in outputs.iter_mut() {
            encoded_frames.push(encoder.encode(&images[*index], capture_ns)?);
        }
        let video = EncodedVideo {
            frames: encoded_frames,
            images,
        };
        if encoded.send(video).is_err() {
            break;
        }
    }
    for (_, encoder) in outputs {
        encoder.stop()?;
    }
    Ok(())
}
