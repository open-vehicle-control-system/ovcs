//! A JPEG request's image, decoded to RGB by libjpeg-turbo, as `jpeg_codec` decodes it for a
//! pipeline that sends pixels. The networks share one decoder, which keeps the frames it
//! decoded last: a frame's JPEG sent to detection and to segmentation is decoded once.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use turbojpeg::{Decompressor, Image, PixelFormat};

/// How many decoded frames the shared decoder keeps.
const KEPT_FRAMES: usize = 2;

/// A decoded frame: `width` × `height` RGB pixels, row-major.
#[derive(Debug, PartialEq)]
pub struct Decoded {
    pub width: u16,
    pub height: u16,
    pub pixels: Vec<u8>,
}

/// One decoder for every network's thread, and the frames it decoded last by their JPEG.
pub struct SharedDecoder {
    state: Mutex<Decoding>,
}

struct Decoding {
    decoder: RgbDecoder,
    /// The newest first, each with the JPEG it was decoded from.
    kept: VecDeque<(Vec<u8>, Arc<Decoded>)>,
}

impl SharedDecoder {
    pub fn new() -> Result<Arc<SharedDecoder>, String> {
        Ok(Arc::new(SharedDecoder {
            state: Mutex::new(Decoding {
                decoder: RgbDecoder::new()?,
                kept: VecDeque::with_capacity(KEPT_FRAMES),
            }),
        }))
    }

    /// `jpeg` decoded, or the frame already decoded from the same bytes. A network asking for
    /// a frame another is decoding waits for it rather than decoding it again.
    pub fn decode(&self, jpeg: &[u8]) -> Result<Arc<Decoded>, String> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let Decoding { decoder, kept } = &mut *state;
        if let Some((_, decoded)) = kept.iter().find(|(bytes, _)| bytes.as_slice() == jpeg) {
            return Ok(Arc::clone(decoded));
        }
        // The oldest frame's pixels are reused once no network holds them any more.
        let mut pixels = match kept.len() {
            KEPT_FRAMES => kept
                .pop_back()
                .and_then(|(_, oldest)| Arc::try_unwrap(oldest).ok())
                .map(|oldest| oldest.pixels)
                .unwrap_or_default(),
            _ => Vec::new(),
        };
        let (width, height) = decoder.decode(jpeg, &mut pixels)?;
        let decoded = Arc::new(Decoded {
            width,
            height,
            pixels,
        });
        kept.push_front((jpeg.to_vec(), Arc::clone(&decoded)));
        Ok(decoded)
    }
}

pub struct RgbDecoder {
    decompressor: Decompressor,
}

impl RgbDecoder {
    pub fn new() -> Result<RgbDecoder, String> {
        let decompressor =
            Decompressor::new().map_err(|error| format!("libjpeg-turbo: {error}"))?;
        Ok(RgbDecoder { decompressor })
    }

    /// `jpeg`'s width and height, its RGB pixels written row-major into `pixels`, resized to
    /// them. A JPEG's sides fit a u16.
    pub fn decode(&mut self, jpeg: &[u8], pixels: &mut Vec<u8>) -> Result<(u16, u16), String> {
        let header = self
            .decompressor
            .read_header(jpeg)
            .map_err(|error| format!("not a JPEG: {error}"))?;
        let (width, height) = (header.width, header.height);
        let pitch = width * 3;
        pixels.resize(pitch * height, 0);
        self.decompressor
            .decompress(
                jpeg,
                Image {
                    pixels: pixels.as_mut_slice(),
                    width,
                    pitch,
                    height,
                    format: PixelFormat::RGB,
                },
            )
            .map_err(|error| format!("a {width}x{height} JPEG: {error}"))?;
        Ok((width as u16, height as u16))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use turbojpeg::{Compressor, Subsamp};

    fn compressed(width: usize, height: usize, format: PixelFormat) -> Vec<u8> {
        let channels = format.size();
        let pixels: Vec<u8> = (0..width * height * channels)
            .map(|at| ((at * 37) % 251) as u8)
            .collect();
        let mut compressor = Compressor::new().unwrap();
        compressor.set_quality(85).unwrap();
        compressor
            .set_subsamp(if channels == 1 {
                Subsamp::Gray
            } else {
                Subsamp::Sub2x1
            })
            .unwrap();
        compressor
            .compress_to_vec(Image {
                pixels: pixels.as_slice(),
                width,
                pitch: width * channels,
                height,
                format,
            })
            .unwrap()
    }

    #[test]
    fn decodes_the_pixels_jpeg_codec_decodes() {
        let mut decoder = RgbDecoder::new().unwrap();
        let mut pixels = Vec::new();
        for (width, height) in [(64, 48), (30, 20)] {
            let jpeg = compressed(width, height, PixelFormat::RGB);
            let expected = turbojpeg::decompress(&jpeg, PixelFormat::RGB).unwrap();
            assert_eq!(
                decoder.decode(&jpeg, &mut pixels),
                Ok((width as u16, height as u16))
            );
            assert_eq!(pixels, expected.pixels);
        }
    }

    #[test]
    fn decodes_a_grey_jpeg_to_its_luma_in_each_channel() {
        let jpeg = compressed(16, 8, PixelFormat::GRAY);
        let luma = turbojpeg::decompress(&jpeg, PixelFormat::GRAY).unwrap();
        let mut decoder = RgbDecoder::new().unwrap();
        let mut pixels = Vec::new();
        assert_eq!(decoder.decode(&jpeg, &mut pixels), Ok((16, 8)));
        let expected: Vec<u8> = luma.pixels.iter().flat_map(|&y| [y, y, y]).collect();
        assert_eq!(pixels, expected);
    }

    #[test]
    fn the_shared_decoder_decodes_a_frame_once_for_every_network() {
        let decoder = SharedDecoder::new().unwrap();
        let (first, second) = (
            compressed(16, 8, PixelFormat::RGB),
            compressed(24, 8, PixelFormat::RGB),
        );
        let decoded = decoder.decode(&first).unwrap();
        let expected = turbojpeg::decompress(&first, PixelFormat::RGB).unwrap();
        assert_eq!((decoded.width, decoded.height), (16, 8));
        assert_eq!(decoded.pixels, expected.pixels);
        assert!(Arc::ptr_eq(&decoded, &decoder.decode(&first).unwrap()));
        let other = decoder.decode(&second).unwrap();
        assert_eq!(other.width, 24);
        assert!(Arc::ptr_eq(&decoded, &decoder.decode(&first).unwrap()));
    }

    #[test]
    fn the_shared_decoder_keeps_the_last_two_frames() {
        let decoder = SharedDecoder::new().unwrap();
        let jpegs: Vec<Vec<u8>> = [16, 24, 32]
            .into_iter()
            .map(|width| compressed(width, 8, PixelFormat::RGB))
            .collect();
        let first = decoder.decode(&jpegs[0]).unwrap();
        decoder.decode(&jpegs[1]).unwrap();
        decoder.decode(&jpegs[2]).unwrap();
        let again = decoder.decode(&jpegs[0]).unwrap();
        assert!(!Arc::ptr_eq(&first, &again));
        assert_eq!(first, again);
    }

    #[test]
    fn the_shared_decoder_refuses_data_that_is_not_a_jpeg() {
        let decoder = SharedDecoder::new().unwrap();
        assert!(decoder.decode(b"not a jpeg").is_err());
    }

    #[test]
    fn refuses_data_that_is_not_a_jpeg() {
        let mut decoder = RgbDecoder::new().unwrap();
        assert!(decoder.decode(b"not a jpeg", &mut Vec::new()).is_err());
    }
}
