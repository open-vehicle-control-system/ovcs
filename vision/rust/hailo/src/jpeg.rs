//! A JPEG request's image, decoded to RGB by libjpeg-turbo, as `jpeg_codec` decodes it for a
//! pipeline that sends pixels.

use turbojpeg::{Decompressor, Image, PixelFormat};

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
    fn refuses_data_that_is_not_a_jpeg() {
        let mut decoder = RgbDecoder::new().unwrap();
        assert!(decoder.decode(b"not a jpeg", &mut Vec::new()).is_err());
    }
}
