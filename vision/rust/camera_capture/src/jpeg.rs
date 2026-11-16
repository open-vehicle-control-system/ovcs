//! The JPEG encoder of the frames and outputs, on TurboJPEG.

use std::ffi::{c_char, c_int, c_uchar, c_ulong, c_void, CStr};

use crate::capture::ConfiguredStream;
use crate::dmabuf::YuvView;
use crate::full_range::{self, chroma_size, Expansion};
use crate::layout;

/// The YUV420 planes and strides turbojpeg encodes.
#[derive(Clone, Copy)]
pub(crate) struct YuvPlanes<'a> {
    planes: [&'a [u8]; 3],
    strides: [usize; 3],
}

/// A stream's frames as its JPEGs are encoded from: as captured, or expanded
/// to full range when the stream is limited range.
pub(crate) struct JpegPlanes {
    width: usize,
    height: usize,
    expansion: Option<Box<Expansion>>,
}

impl JpegPlanes {
    pub(crate) fn new(stream: &ConfiguredStream) -> JpegPlanes {
        JpegPlanes {
            width: stream.size.width as usize,
            height: stream.size.height as usize,
            expansion: full_range::expands(stream.range).then(Box::default),
        }
    }

    /// `view`'s planes, read between the dmabuf syncs.
    pub(crate) fn of<'a>(&'a mut self, view: &'a YuvView) -> YuvPlanes<'a> {
        let Some(expansion) = &mut self.expansion else {
            return YuvPlanes {
                planes: std::array::from_fn(|plane| view.plane(plane)),
                strides: view.strides,
            };
        };
        let (chroma_width, chroma_height) = chroma_size(self.width, self.height);
        let sizes = [
            (self.width, self.height),
            (chroma_width, chroma_height),
            (chroma_width, chroma_height),
        ];
        let planes: [&[u8]; 3] = std::array::from_fn(|plane| view.plane(plane));
        let expanded = expansion.expand(planes, view.strides, self.width, self.height);
        YuvPlanes {
            planes: expanded,
            strides: sizes.map(|(width, _)| width),
        }
    }
}

type TjHandle = *mut c_void;

const TJSAMP_420: c_int = 2;
const TJFLAG_NOREALLOC: c_int = 1024;
const TJFLAG_FASTDCT: c_int = 2048;

// TurboJPEG's C API rather than the turbojpeg crate: tjCompressFromYUVPlanes takes each
// plane from its own pointer and stride, so a frame is encoded straight from its mapping.
extern "C" {
    fn tjInitCompress() -> TjHandle;
    fn tjDestroy(handle: TjHandle) -> c_int;
    fn tjBufSize(width: c_int, height: c_int, subsamp: c_int) -> c_ulong;
    fn tjAlloc(bytes: c_int) -> *mut c_uchar;
    fn tjFree(buffer: *mut c_uchar);
    fn tjGetErrorStr2(handle: TjHandle) -> *mut c_char;
    fn tjCompressFromYUVPlanes(
        handle: TjHandle,
        src_planes: *mut *const c_uchar,
        width: c_int,
        strides: *const c_int,
        height: c_int,
        subsamp: c_int,
        jpeg_buf: *mut *mut c_uchar,
        jpeg_size: *mut c_ulong,
        jpeg_qual: c_int,
        flags: c_int,
    ) -> c_int;
}

/// TurboJPEG into one buffer of the largest size a frame can take, so no
/// allocation happens per frame.
pub(crate) struct JpegEncoder {
    handle: TjHandle,
    buffer: *mut c_uchar,
    capacity: c_ulong,
    width: c_int,
    height: c_int,
    quality: c_int,
}

impl JpegEncoder {
    /// At `quality`, 1 to 100; the chroma stays the YUV420 frame's 4:2:0.
    pub(crate) fn new(width: u32, height: u32, quality: c_int) -> Result<JpegEncoder, String> {
        let (Ok(width), Ok(height)) = (c_int::try_from(width), c_int::try_from(height)) else {
            return Err(format!("no JPEG of {width}x{height}"));
        };
        // SAFETY: TurboJPEG C API; the handle and buffer are freed in Drop.
        unsafe {
            let handle = tjInitCompress();
            if handle.is_null() {
                return Err("tjInitCompress failed".to_string());
            }
            let capacity = tjBufSize(width, height, TJSAMP_420);
            let buffer = tjAlloc(capacity as c_int);
            if buffer.is_null() {
                tjDestroy(handle);
                return Err(format!("tjAlloc({capacity}) failed"));
            }
            Ok(JpegEncoder {
                handle,
                buffer,
                capacity,
                width,
                height,
                quality,
            })
        }
    }

    /// Refuses planes shorter than this encoder's frame size takes at their strides.
    pub(crate) fn encode(&mut self, yuv: YuvPlanes) -> Result<&[u8], String> {
        let (width, height) = (self.width as usize, self.height as usize);
        let lengths = layout::jpeg_plane_lengths(width, height, yuv.strides);
        let short = |lengths: [usize; 3]| {
            (yuv.planes.iter().zip(lengths)).any(|(plane, length)| plane.len() < length)
        };
        if lengths.is_none_or(short) {
            return Err(format!(
                "planes of {:?} bytes {:?} apart are no {width}x{height} frame",
                yuv.planes.map(<[u8]>::len),
                yuv.strides
            ));
        }
        let strides = match yuv.strides.map(c_int::try_from) {
            [Ok(y_stride), Ok(u_stride), Ok(v_stride)] => [y_stride, u_stride, v_stride],
            _ => return Err(format!("strides {:?} past a C int", yuv.strides)),
        };
        let mut planes = yuv.planes.map(<[u8]>::as_ptr);
        let mut size = self.capacity;
        // SAFETY: each plane holds the rows TurboJPEG reads of this frame size, checked above;
        // NOREALLOC keeps the buffer.
        unsafe {
            let status = tjCompressFromYUVPlanes(
                self.handle,
                planes.as_mut_ptr(),
                self.width,
                strides.as_ptr(),
                self.height,
                TJSAMP_420,
                &mut self.buffer,
                &mut size,
                self.quality,
                TJFLAG_FASTDCT | TJFLAG_NOREALLOC,
            );
            if status != 0 {
                return Err(CStr::from_ptr(tjGetErrorStr2(self.handle))
                    .to_string_lossy()
                    .into_owned());
            }
            Ok(std::slice::from_raw_parts(self.buffer, size as usize))
        }
    }
}

impl Drop for JpegEncoder {
    fn drop(&mut self) {
        // SAFETY: both were allocated by TurboJPEG in `new`.
        unsafe {
            tjFree(self.buffer);
            tjDestroy(self.handle);
        }
    }
}
