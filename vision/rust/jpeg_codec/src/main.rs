//! JPEG Port for `VisionCore.Jpeg`. Each `{:packet, 4}` request starts with an
//! operation byte:
//!
//! - 0, encode: `width: u16, height: u16, channels: u8 (1 grey or 3 RGB),
//!   quality: u8`, little-endian, then the pixels row-major; the reply is the
//!   JPEG.
//! - 1, decode: a JPEG; the reply is `width: u16, height: u16`, little-endian,
//!   then its luma plane, one byte a pixel.
//! - 2, depth: `width: u16, height: u16, quality: u8, near_mm: u16, far_mm:
//!   u16`, then the depth in millimetres as u16, 0 where unmeasured; the reply
//!   is the depth coloured with OpenCV's turbo map by 1/depth, near red and far
//!   blue, as a JPEG. A `near_mm` of 0 is the 2nd percentile of the depth; a
//!   `far_mm` of 0 is infinitely far, so the colours do not follow the
//!   farthest stray matches from one image to the next.
//!
//! A malformed request gets an empty reply.

use std::io::{self, Write};

use jpeg_decoder::{Decoder, PixelFormat};
use jpeg_encoder::{ColorType, Encoder};

const ENCODE: u8 = 0;
const DECODE: u8 = 1;
const DEPTH: u8 = 2;
const ENCODE_HEADER: usize = 6;
const DEPTH_HEADER: usize = 9;

// OpenCV's COLORMAP_TURBO, as RGB.
const TURBO: [[u8; 3]; 256] = [
    [48, 18, 59],
    [50, 21, 67],
    [51, 24, 74],
    [52, 27, 81],
    [53, 30, 88],
    [54, 33, 95],
    [55, 36, 102],
    [56, 39, 109],
    [57, 42, 115],
    [58, 45, 121],
    [59, 47, 128],
    [60, 50, 134],
    [61, 53, 139],
    [62, 56, 145],
    [63, 59, 151],
    [63, 62, 156],
    [64, 64, 162],
    [65, 67, 167],
    [65, 70, 172],
    [66, 73, 177],
    [66, 75, 181],
    [67, 78, 186],
    [68, 81, 191],
    [68, 84, 195],
    [68, 86, 199],
    [69, 89, 203],
    [69, 92, 207],
    [69, 94, 211],
    [70, 97, 214],
    [70, 100, 218],
    [70, 102, 221],
    [70, 105, 224],
    [70, 107, 227],
    [71, 110, 230],
    [71, 113, 233],
    [71, 115, 235],
    [71, 118, 238],
    [71, 120, 240],
    [71, 123, 242],
    [70, 125, 244],
    [70, 128, 246],
    [70, 130, 248],
    [70, 133, 250],
    [70, 135, 251],
    [69, 138, 252],
    [69, 140, 253],
    [68, 143, 254],
    [67, 145, 254],
    [66, 148, 255],
    [65, 150, 255],
    [64, 153, 255],
    [62, 155, 254],
    [61, 158, 254],
    [59, 160, 253],
    [58, 163, 252],
    [56, 165, 251],
    [55, 168, 250],
    [53, 171, 248],
    [51, 173, 247],
    [49, 175, 245],
    [47, 178, 244],
    [46, 180, 242],
    [44, 183, 240],
    [42, 185, 238],
    [40, 188, 235],
    [39, 190, 233],
    [37, 192, 231],
    [35, 195, 228],
    [34, 197, 226],
    [32, 199, 223],
    [31, 201, 221],
    [30, 203, 218],
    [28, 205, 216],
    [27, 208, 213],
    [26, 210, 210],
    [26, 212, 208],
    [25, 213, 205],
    [24, 215, 202],
    [24, 217, 200],
    [24, 219, 197],
    [24, 221, 194],
    [24, 222, 192],
    [24, 224, 189],
    [25, 226, 187],
    [25, 227, 185],
    [26, 228, 182],
    [28, 230, 180],
    [29, 231, 178],
    [31, 233, 175],
    [32, 234, 172],
    [34, 235, 170],
    [37, 236, 167],
    [39, 238, 164],
    [42, 239, 161],
    [44, 240, 158],
    [47, 241, 155],
    [50, 242, 152],
    [53, 243, 148],
    [56, 244, 145],
    [60, 245, 142],
    [63, 246, 138],
    [67, 247, 135],
    [70, 248, 132],
    [74, 248, 128],
    [78, 249, 125],
    [82, 250, 122],
    [85, 250, 118],
    [89, 251, 115],
    [93, 252, 111],
    [97, 252, 108],
    [101, 253, 105],
    [105, 253, 102],
    [109, 254, 98],
    [113, 254, 95],
    [117, 254, 92],
    [121, 254, 89],
    [125, 255, 86],
    [128, 255, 83],
    [132, 255, 81],
    [136, 255, 78],
    [139, 255, 75],
    [143, 255, 73],
    [146, 255, 71],
    [150, 254, 68],
    [153, 254, 66],
    [156, 254, 64],
    [159, 253, 63],
    [161, 253, 61],
    [164, 252, 60],
    [167, 252, 58],
    [169, 251, 57],
    [172, 251, 56],
    [175, 250, 55],
    [177, 249, 54],
    [180, 248, 54],
    [183, 247, 53],
    [185, 246, 53],
    [188, 245, 52],
    [190, 244, 52],
    [193, 243, 52],
    [195, 241, 52],
    [198, 240, 52],
    [200, 239, 52],
    [203, 237, 52],
    [205, 236, 52],
    [208, 234, 52],
    [210, 233, 53],
    [212, 231, 53],
    [215, 229, 53],
    [217, 228, 54],
    [219, 226, 54],
    [221, 224, 55],
    [223, 223, 55],
    [225, 221, 55],
    [227, 219, 56],
    [229, 217, 56],
    [231, 215, 57],
    [233, 213, 57],
    [235, 211, 57],
    [236, 209, 58],
    [238, 207, 58],
    [239, 205, 58],
    [241, 203, 58],
    [242, 201, 58],
    [244, 199, 58],
    [245, 197, 58],
    [246, 195, 58],
    [247, 193, 58],
    [248, 190, 57],
    [249, 188, 57],
    [250, 186, 57],
    [251, 184, 56],
    [251, 182, 55],
    [252, 179, 54],
    [252, 177, 54],
    [253, 174, 53],
    [253, 172, 52],
    [254, 169, 51],
    [254, 167, 50],
    [254, 164, 49],
    [254, 161, 48],
    [254, 158, 47],
    [254, 155, 45],
    [254, 153, 44],
    [254, 150, 43],
    [254, 147, 42],
    [254, 144, 41],
    [253, 141, 39],
    [253, 138, 38],
    [252, 135, 37],
    [252, 132, 35],
    [251, 129, 34],
    [251, 126, 33],
    [250, 123, 31],
    [249, 120, 30],
    [249, 117, 29],
    [248, 114, 28],
    [247, 111, 26],
    [246, 108, 25],
    [245, 105, 24],
    [244, 102, 23],
    [243, 99, 21],
    [242, 96, 20],
    [241, 93, 19],
    [240, 91, 18],
    [239, 88, 17],
    [237, 85, 16],
    [236, 83, 15],
    [235, 80, 14],
    [234, 78, 13],
    [232, 75, 12],
    [231, 73, 12],
    [229, 71, 11],
    [228, 69, 10],
    [226, 67, 10],
    [225, 65, 9],
    [223, 63, 8],
    [221, 61, 8],
    [220, 59, 7],
    [218, 57, 7],
    [216, 55, 6],
    [214, 53, 6],
    [212, 51, 5],
    [210, 49, 5],
    [208, 47, 5],
    [206, 45, 4],
    [204, 43, 4],
    [202, 42, 4],
    [200, 40, 3],
    [197, 38, 3],
    [195, 37, 3],
    [193, 35, 2],
    [190, 33, 2],
    [188, 32, 2],
    [185, 30, 2],
    [183, 29, 2],
    [180, 27, 1],
    [178, 26, 1],
    [175, 24, 1],
    [172, 23, 1],
    [169, 22, 1],
    [167, 20, 1],
    [164, 19, 1],
    [161, 18, 1],
    [158, 16, 1],
    [155, 15, 1],
    [152, 14, 1],
    [149, 13, 1],
    [146, 11, 1],
    [142, 10, 1],
    [139, 9, 2],
    [136, 8, 2],
    [133, 7, 2],
    [129, 6, 2],
    [126, 5, 2],
    [122, 4, 3],
];

fn handle(request: &[u8]) -> Option<Vec<u8>> {
    match request.split_first()? {
        (&ENCODE, body) => encode(body),
        (&DECODE, body) => decode_luma(body),
        (&DEPTH, body) => encode_depth(body),
        _ => None,
    }
}

fn encode(request: &[u8]) -> Option<Vec<u8>> {
    let header = request.get(..ENCODE_HEADER)?;
    let width = u16::from_le_bytes([header[0], header[1]]);
    let height = u16::from_le_bytes([header[2], header[3]]);
    let (channels, quality) = (header[4], header[5]);
    let color = match channels {
        1 => ColorType::Luma,
        3 => ColorType::Rgb,
        _ => return None,
    };
    let pixels = &request[ENCODE_HEADER..];
    if width == 0
        || height == 0
        || pixels.len() != width as usize * height as usize * channels as usize
    {
        return None;
    }
    let mut jpeg = Vec::new();
    Encoder::new(&mut jpeg, quality.clamp(1, 100))
        .encode(pixels, width, height, color)
        .ok()?;
    Some(jpeg)
}

// A colour JPEG's luma is computed back from its RGB with BT.601 weights,
// within rounding of the stored Y samples a grayscale decode gives.
fn decode_luma(jpeg: &[u8]) -> Option<Vec<u8>> {
    let mut decoder = Decoder::new(jpeg);
    let samples = decoder.decode().ok()?;
    let info = decoder.info()?;
    let mut reply = Vec::with_capacity(4 + info.width as usize * info.height as usize);
    reply.extend_from_slice(&info.width.to_le_bytes());
    reply.extend_from_slice(&info.height.to_le_bytes());
    match info.pixel_format {
        PixelFormat::L8 => reply.extend_from_slice(&samples),
        PixelFormat::RGB24 => reply.extend(samples.chunks_exact(3).map(|rgb| {
            let [r, g, b] = [rgb[0], rgb[1], rgb[2]].map(u32::from);
            ((77 * r + 150 * g + 29 * b + 128) >> 8) as u8
        })),
        _ => return None,
    }
    Some(reply)
}

fn encode_depth(request: &[u8]) -> Option<Vec<u8>> {
    let header = request.get(..DEPTH_HEADER)?;
    let u16_at = |i: usize| u16::from_le_bytes([header[i], header[i + 1]]);
    let (width, height, quality) = (u16_at(0), u16_at(2), header[4]);
    let (near_mm, far_mm) = (u16_at(5), u16_at(7));
    let samples = &request[DEPTH_HEADER..];
    if width == 0 || height == 0 || samples.len() != width as usize * height as usize * 2 {
        return None;
    }
    let depth: Vec<u16> = samples
        .chunks_exact(2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .collect();
    let near = if near_mm == 0 {
        near_percentile(&depth)
    } else {
        Some(near_mm)
    };
    let far = if far_mm == 0 { u16::MAX } else { far_mm };
    let range = near.map(|near| (near, far.max(near.saturating_add(1))));
    let mut jpeg = Vec::new();
    Encoder::new(&mut jpeg, quality.clamp(1, 100))
        .encode(&depth_colours(&depth, range), width, height, ColorType::Rgb)
        .ok()?;
    Some(jpeg)
}

/// The 2nd percentile of the measured depths, so a few stray near matches do
/// not set the colours' near end; `None` without any.
fn near_percentile(depth_mm: &[u16]) -> Option<u16> {
    let mut histogram = vec![0u32; 65_536];
    let mut measured = 0u32;
    for &d in depth_mm.iter().filter(|&&d| d > 0) {
        histogram[usize::from(d)] += 1;
        measured += 1;
    }
    if measured == 0 {
        return None;
    }
    let at = |share: u32| {
        let wanted = (measured * share).div_ceil(100).max(1);
        let mut seen = 0;
        histogram
            .iter()
            .position(|&count| {
                seen += count;
                seen >= wanted
            })
            .unwrap_or(0) as u16
    };
    Some(at(2))
}

/// RGB per pixel: `near_mm` red through `far_mm` blue, black without depth.
/// The colours follow 1/depth, as disparity does, so the near metres a
/// stereo pair measures best spread over the map and far ones share its end.
fn depth_colours(depth_mm: &[u16], range: Option<(u16, u16)>) -> Vec<u8> {
    let (near, far) = range.unwrap_or((1, 2));
    let inverse = |mm: u16| 1.0 / f32::from(mm.max(1));
    let (inverse_near, inverse_far) = (inverse(near), inverse(far.max(near.saturating_add(1))));
    depth_mm
        .iter()
        .flat_map(|&d| {
            if d == 0 {
                [0, 0, 0]
            } else {
                let t =
                    ((inverse_near - inverse(d)) / (inverse_near - inverse_far)).clamp(0.0, 1.0);
                TURBO[255 - (t * 255.0).round() as usize]
            }
        })
        .collect()
}

fn main() -> io::Result<()> {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    while let Some(request) = framing::read_record(&mut input)? {
        let reply = handle(&request).unwrap_or_default();
        output.write_all(&(reply.len() as u32).to_be_bytes())?;
        output.write_all(&reply)?;
        output.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(width: u16, height: u16, channels: u8, pixels: &[u8]) -> Vec<u8> {
        let mut request = vec![ENCODE];
        request.extend_from_slice(&width.to_le_bytes());
        request.extend_from_slice(&height.to_le_bytes());
        request.extend_from_slice(&[channels, 80]);
        request.extend_from_slice(pixels);
        request
    }

    fn is_jpeg(bytes: &[u8]) -> bool {
        bytes.starts_with(&[0xFF, 0xD8]) && bytes.ends_with(&[0xFF, 0xD9])
    }

    #[test]
    fn encodes_grey_and_rgb() {
        let grey: Vec<u8> = (0..16 * 8).map(|i| i as u8).collect();
        assert!(is_jpeg(&handle(&request(16, 8, 1, &grey)).unwrap()));

        let rgb = vec![200u8; 16 * 8 * 3];
        assert!(is_jpeg(&handle(&request(16, 8, 3, &rgb)).unwrap()));
    }

    fn decode_request(jpeg: &[u8]) -> Vec<u8> {
        let mut request = vec![DECODE];
        request.extend_from_slice(jpeg);
        request
    }

    #[test]
    fn decodes_to_the_luma_plane() {
        let grey: Vec<u8> = (0..32 * 16).map(|i| (i % 32 * 8) as u8).collect();
        let jpeg = handle(&request(32, 16, 1, &grey)).unwrap();
        let reply = handle(&decode_request(&jpeg)).unwrap();

        assert_eq!(&reply[..4], &[32, 0, 16, 0]);
        let pixels = &reply[4..];
        assert_eq!(pixels.len(), 32 * 16);
        assert!(pixels.iter().zip(&grey).all(|(a, b)| a.abs_diff(*b) <= 8));
    }

    #[test]
    fn decodes_a_colour_jpeg_to_its_luma() {
        let rgb: Vec<u8> = [128u8, 128, 128].repeat(16 * 8);
        let jpeg = handle(&request(16, 8, 3, &rgb)).unwrap();
        let reply = handle(&decode_request(&jpeg)).unwrap();

        assert!(reply[4..].iter().all(|v| v.abs_diff(128) <= 2));
    }

    fn depth_request(
        width: u16,
        height: u16,
        near_mm: u16,
        far_mm: u16,
        depth_mm: &[u16],
    ) -> Vec<u8> {
        let mut request = vec![DEPTH];
        request.extend_from_slice(&width.to_le_bytes());
        request.extend_from_slice(&height.to_le_bytes());
        request.push(90);
        request.extend_from_slice(&near_mm.to_le_bytes());
        request.extend_from_slice(&far_mm.to_le_bytes());
        request.extend(depth_mm.iter().flat_map(|d| d.to_le_bytes()));
        request
    }

    #[test]
    fn colours_near_red_far_blue_and_no_depth_black() {
        let colours = depth_colours(&[1_000, 3_000, 0], Some((1_000, 3_000)));
        assert_eq!(colours, [122, 4, 3, 48, 18, 59, 0, 0, 0]);
    }

    #[test]
    fn colours_by_inverse_depth_so_near_differences_show() {
        // 1.5 m is halfway between 1 m and 3 m in 1/depth.
        let colours = depth_colours(&[1_500], Some((1_000, 3_000)));
        assert!(
            colours == TURBO[127] || colours == TURBO[128],
            "{colours:?}"
        );
    }

    #[test]
    fn the_automatic_near_end_ignores_outliers() {
        let mut depth = vec![2_000u16; 98];
        depth.extend([100, 60_000]);
        assert_eq!(near_percentile(&depth), Some(2_000));
    }

    #[test]
    fn encodes_a_depth_preview() {
        let depth: Vec<u16> = (0..16 * 8).map(|i| 500 + i * 20).collect();
        let jpeg = handle(&depth_request(16, 8, 0, 0, &depth)).unwrap();
        assert!(is_jpeg(&jpeg));
        assert_eq!(handle(&depth_request(16, 8, 0, 0, &depth[..10])), None);
    }

    #[test]
    fn refuses_data_that_is_not_a_jpeg() {
        assert_eq!(handle(&decode_request(b"not a jpeg")), None);
    }

    #[test]
    fn refuses_a_malformed_request() {
        assert_eq!(handle(&request(16, 8, 1, &[0; 10])), None);
        assert_eq!(handle(&request(16, 8, 2, &[0; 256])), None);
        assert_eq!(handle(&[ENCODE, 1, 2]), None);
        assert_eq!(handle(&[9]), None);
        assert_eq!(handle(&[]), None);
    }
}
