//! The capture's dmabufs, mapped for the CPU to read.

use std::collections::HashMap;
use std::ffi::c_void;
use std::os::fd::RawFd;

use libcamera::framebuffer::AsFrameBuffer;

use crate::capture::ConfiguredStream;
use crate::layout;

/// One buffer's planes, mapped.
pub(crate) fn map_view(
    mapper: &mut FdMapper,
    buffer: &impl AsFrameBuffer,
    stream: &ConfiguredStream,
) -> Result<YuvView, String> {
    let y_stride = stream.stride;
    // libcamera's YUV420 packs U and V at half the line stride: the I420 layout turbojpeg expects.
    let uv_stride = y_stride / 2;
    let planes = buffer.planes();
    if planes.is_empty() {
        return Err("buffer has no planes".to_string());
    }
    let plane = |plane_index: usize| {
        let plane = planes.get(plane_index).expect("plane in range");
        (plane.fd(), plane.offset().unwrap_or(0))
    };
    let mut sync_fds = Vec::new();
    let mut map = |(fd, offset, length): (RawFd, usize, usize)| {
        if !sync_fds.contains(&fd) {
            sync_fds.push(fd);
        }
        (mapper.map_plane(fd, offset, length))
            .map_err(|map_error| format!("mapping a plane of fd {fd} failed: {map_error}"))
    };
    let (width, height) = (stream.size.width as usize, stream.size.height as usize);
    let strides = [y_stride, uv_stride, uv_stride];
    let lengths = layout::plane_lengths(width, height, strides);
    let (y, u, v) = if planes.len() >= 3 {
        let mut map_read = |plane_index: usize| {
            let (fd, offset) = plane(plane_index);
            map((fd, offset, lengths[plane_index]))
        };
        (map_read(0)?, map_read(1)?, map_read(2)?)
    } else {
        // Single-plane dmabuf: Y, U and V at known offsets within it.
        let y_size = y_stride * height;
        let uv_size = uv_stride * (height / 2);
        let (fd, offset) = plane(0);
        let base = map((fd, offset, y_size + uv_size + lengths[2]))?;
        // SAFETY: map_plane checked that the mapping holds y_size + uv_size + lengths[2] bytes
        // from base, which covers the U and V planes read from these offsets.
        unsafe { (base, base.add(y_size), base.add(y_size + uv_size)) }
    };
    Ok(YuvView {
        planes: [y, u, v],
        lengths,
        strides,
        sync_fds,
    })
}

/// One mmap per dmabuf fd: libcamera often carves several planes out of one buffer.
#[derive(Default)]
pub(crate) struct FdMapper {
    maps: HashMap<RawFd, (*mut c_void, usize)>,
}

impl FdMapper {
    /// The start of `length` bytes at `offset` in the dmabuf `fd`, refused when
    /// its mapping does not hold them.
    fn map_plane(&mut self, fd: RawFd, offset: usize, length: usize) -> std::io::Result<*const u8> {
        let (base, total) = match self.maps.get(&fd) {
            Some(&mapping) => mapping,
            None => {
                // The whole dmabuf, which is usually larger than one plane.
                // SAFETY: fd is a dmabuf owned by the allocator, mapped read-only.
                let end = unsafe { libc::lseek(fd, 0, libc::SEEK_END) };
                let total = if end > 0 {
                    end as usize
                } else {
                    offset + length
                };
                // SAFETY: a fresh read-only shared mapping of `total` bytes of the dmabuf.
                let base = unsafe {
                    libc::mmap(
                        std::ptr::null_mut(),
                        total,
                        libc::PROT_READ,
                        libc::MAP_SHARED,
                        fd,
                        0,
                    )
                };
                if base == libc::MAP_FAILED {
                    return Err(std::io::Error::last_os_error());
                }
                self.maps.insert(fd, (base, total));
                (base, total)
            }
        };
        if !layout::holds(total, offset, length) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("{length} bytes at {offset} overrun its {total}-byte mapping"),
            ));
        }
        // SAFETY: the mapping holds `length` bytes from `offset`.
        Ok(unsafe { (base as *const u8).add(offset) })
    }
}

impl Drop for FdMapper {
    fn drop(&mut self) {
        for (base, length) in self.maps.values() {
            // SAFETY: each entry is a live mapping created by map_plane.
            unsafe { libc::munmap(*base, *length) };
        }
    }
}

/// Plane pointers of one buffer, resolved once.
pub(crate) struct YuvView {
    planes: [*const u8; 3],
    /// The bytes map_view checked each plane's mapping holds.
    lengths: [usize; 3],
    pub(crate) strides: [usize; 3],
    pub(crate) sync_fds: Vec<RawFd>,
}

impl YuvView {
    /// Plane `index`'s bytes, read between the dmabuf syncs.
    pub(crate) fn plane(&self, index: usize) -> &[u8] {
        // SAFETY: map_view checked the mapping holds `lengths[index]` bytes from
        // `planes[index]`, and the FdMapper that keeps it mapped outlives every view.
        unsafe { std::slice::from_raw_parts(self.planes[index], self.lengths[index]) }
    }
}

pub(crate) const DMA_BUF_SYNC_READ: u64 = 1;
pub(crate) const DMA_BUF_SYNC_START: u64 = 0;
pub(crate) const DMA_BUF_SYNC_END: u64 = 1 << 2;
// _IOW('b', 0, struct dma_buf_sync)
const DMA_BUF_IOCTL_SYNC: libc::c_ulong = 0x4008_6200;

pub(crate) fn dmabuf_sync(sync_fds: &[RawFd], flags: u64) {
    for fd in sync_fds {
        // Failure ignored: the worst case is one stale cache line.
        // SAFETY: `flags` matches struct dma_buf_sync, a single u64.
        unsafe { libc::ioctl(*fd, DMA_BUF_IOCTL_SYNC as _, &flags) };
    }
}
