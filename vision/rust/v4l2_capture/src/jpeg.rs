//! The outputs sent as JPEGs: each encoded with libjpeg-turbo from the
//! image of the output it is made from, averaged first when it is a
//! whole fraction of that image (`scale`), on a thread of its own while
//! the writer writes the frame's other outputs.

use std::io;
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use turbojpeg::{Compressor, Image, PixelFormat, Subsamp};

use crate::arguments::OutputSpec;
use crate::scale::Averager;

/// One output sent as a JPEG.
pub struct JpegOutput {
    /// The index of the output it is encoded from, and that output's width.
    from: usize,
    source_width: usize,
    /// The block of the source's pixels each of its pixels averages.
    block: (usize, usize),
    width: usize,
    height: usize,
    quality: u8,
}

impl JpegOutput {
    /// `spec`, sent as a JPEG at `quality`, encoded from the output `from`,
    /// which is `source`.
    pub fn new(from: usize, source: &OutputSpec, spec: &OutputSpec, quality: u8) -> JpegOutput {
        JpegOutput {
            from,
            source_width: source.width as usize,
            block: spec.block(source),
            width: spec.width as usize,
            height: spec.height as usize,
            quality,
        }
    }
}

/// A frame's JPEGs, one per JPEG output in their order, with the handle
/// on the frame's images the encoder read them from and the time the
/// encodes took.
pub struct Encoded {
    pub jpegs: Vec<Vec<u8>>,
    pub images: Arc<Vec<Vec<u8>>>,
    pub took: Duration,
}

/// Encodes `outputs` from the images of each frame `frames` brings and
/// sends them to `encoded`, until `frames` closes or nothing receives.
pub fn encode_frames(
    outputs: &[JpegOutput],
    frames: mpsc::Receiver<Arc<Vec<Vec<u8>>>>,
    encoded: mpsc::Sender<Encoded>,
) -> io::Result<()> {
    let mut compressor = Compressor::new().map_err(io::Error::other)?;
    let (mut averager, mut averaged) = (Averager::default(), Vec::new());
    for images in frames {
        let encoding = Instant::now();
        let mut jpegs = Vec::with_capacity(outputs.len());
        for output in outputs {
            let source = &images[output.from];
            let pixels = if output.block == (1, 1) {
                source
            } else {
                averager.average_blocks(
                    source,
                    output.source_width,
                    output.block,
                    1,
                    &mut averaged,
                );
                &averaged
            };
            let size = (output.width, output.height);
            jpegs.push(encode(&mut compressor, pixels, size, output.quality)?);
        }
        let took = encoding.elapsed();
        if encoded
            .send(Encoded {
                jpegs,
                images,
                took,
            })
            .is_err()
        {
            break;
        }
    }
    Ok(())
}

/// `pixels`, `width` x `height` 8-bit RGB, as a JPEG at `quality`, its
/// chroma 4:2:0 below quality 90 and 4:4:4 from 90 up, as `jpeg_codec`
/// encodes.
pub fn encode(
    compressor: &mut Compressor,
    pixels: &[u8],
    (width, height): (usize, usize),
    quality: u8,
) -> io::Result<Vec<u8>> {
    let subsampling = if quality < 90 {
        Subsamp::Sub2x2
    } else {
        Subsamp::None
    };
    compressor
        .set_quality(i32::from(quality))
        .and_then(|()| compressor.set_subsamp(subsampling))
        .and_then(|()| {
            compressor.compress_to_vec(Image {
                pixels,
                width,
                pitch: width * 3,
                height,
                format: PixelFormat::RGB,
            })
        })
        .map_err(io::Error::other)
}
