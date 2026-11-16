//! What lets a network skip HailoRT's vstreams: a HEF whose one input and one output stream
//! carry UINT8 in the layout a request's pixels and its class ids already have, so the device
//! reads and writes page-aligned buffers of ours, mapped for DMA, with no copy between.

use std::alloc::{alloc_zeroed, dealloc, Layout};
use std::ptr::NonNull;

/// The order of a stream's bytes, as far as a direct transfer cares.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Order {
    /// Row by row, a pixel's channels together: an RGB input's.
    Nhwc,
    /// Row by row, one value a pixel: an argmax output's class ids.
    Nhw,
    Other,
}

/// A stream of the HEF, as its stream info describes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stream {
    pub input: bool,
    pub uint8: bool,
    pub order: Order,
    /// The shape's bytes, height × width × features.
    pub shape_bytes: usize,
    /// The bytes of a frame as the device transfers it, padding included.
    pub frame_bytes: usize,
}

/// Whether the network's frames can go to and from the device without a vstream: one input
/// stream, RGB row by row, one output stream of class ids, each UINT8 without padding.
pub fn takes_direct(streams: &[Stream]) -> bool {
    let unpadded = |stream: &Stream| stream.uint8 && stream.frame_bytes == stream.shape_bytes;
    match streams {
        [first, second] => {
            let (input, output) = if first.input {
                (first, second)
            } else {
                (second, first)
            };
            input.input
                && !output.input
                && input.order == Order::Nhwc
                && output.order == Order::Nhw
                && unpadded(input)
                && unpadded(output)
        }
        _ => false,
    }
}

/// A zeroed buffer of whole pages, as the device's DMA takes, which no other data shares.
pub struct PageBuffer {
    data: NonNull<u8>,
    len: usize,
    layout: Layout,
}

// SAFETY: the buffer is owned memory, handed to one thread at a time.
unsafe impl Send for PageBuffer {}

impl PageBuffer {
    /// `len` bytes, the allocation rounded up to whole pages of `page_bytes`.
    pub fn new(len: usize, page_bytes: usize) -> PageBuffer {
        let layout = Layout::from_size_align(len.max(1).next_multiple_of(page_bytes), page_bytes)
            .expect("a page-aligned layout");
        // SAFETY: the layout has a non-zero size.
        let data = NonNull::new(unsafe { alloc_zeroed(layout) })
            .unwrap_or_else(|| std::alloc::handle_alloc_error(layout));
        PageBuffer { data, len, layout }
    }

    pub fn as_slice(&self) -> &[u8] {
        // SAFETY: `len` zeroed or written bytes of the allocation, borrowed with `self`.
        unsafe { std::slice::from_raw_parts(self.data.as_ptr(), self.len) }
    }

    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        // SAFETY: as `as_slice`, borrowed mutably with `self`.
        unsafe { std::slice::from_raw_parts_mut(self.data.as_ptr(), self.len) }
    }

    /// The start of the pages, for DMA mapping and the transfers.
    pub fn as_mut_ptr(&mut self) -> *mut u8 {
        self.data.as_ptr()
    }
}

impl Drop for PageBuffer {
    fn drop(&mut self) {
        // SAFETY: allocated in `new` with this layout, freed once.
        unsafe { dealloc(self.data.as_ptr(), self.layout) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(input: bool, order: Order, shape_bytes: usize, frame_bytes: usize) -> Stream {
        Stream {
            input,
            uint8: true,
            order,
            shape_bytes,
            frame_bytes,
        }
    }

    #[test]
    fn takes_an_rgb_input_and_a_class_id_output_without_padding() {
        let streams = [
            stream(true, Order::Nhwc, 24, 24),
            stream(false, Order::Nhw, 8, 8),
        ];
        assert!(takes_direct(&streams));
    }

    #[test]
    fn refuses_what_a_vstream_would_convert() {
        let input = stream(true, Order::Nhwc, 24, 24);
        let output = stream(false, Order::Nhw, 8, 8);
        // A transposed input, as NanoDet's.
        assert!(!takes_direct(&[stream(true, Order::Other, 24, 24), output]));
        // Padded rows.
        assert!(!takes_direct(&[stream(true, Order::Nhwc, 24, 32), output]));
        assert!(!takes_direct(&[input, stream(false, Order::Nhw, 8, 16)]));
        // Not UINT8.
        assert!(!takes_direct(&[
            Stream {
                uint8: false,
                ..input
            },
            output
        ]));
        // Several outputs, as an NMS a vstream finishes on the host.
        assert!(!takes_direct(&[input, output, output]));
        assert!(!takes_direct(&[input]));
        // An output that is an image, not class ids.
        assert!(!takes_direct(&[input, stream(false, Order::Nhwc, 24, 24)]));
    }

    #[test]
    fn a_page_buffer_is_zeroed_whole_pages_aligned_to_a_page() {
        let mut buffer = PageBuffer::new(5000, 4096);
        assert_eq!(buffer.as_slice().len(), 5000);
        assert!(buffer.as_slice().iter().all(|&byte| byte == 0));
        assert_eq!(buffer.as_mut_ptr() as usize % 4096, 0);
        buffer.as_mut_slice()[4999] = 7;
        assert_eq!(buffer.as_slice()[4999], 7);
    }
}
