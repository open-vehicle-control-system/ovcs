//! The V4L2 ioctls `v4l2_capture` uses, on aarch64/x86_64 Linux layouts.

use std::ffi::CString;
use std::fs;
use std::io;
use std::ptr;

const fn ioc(dir: u64, nr: u64, size: u64) -> u64 {
    (dir << 30) | (size << 16) | ((b'V' as u64) << 8) | nr
}
const READ_WRITE: u64 = 3;
const WRITE: u64 = 1;
const VIDIOC_S_FMT: u64 = ioc(READ_WRITE, 5, 208);
const VIDIOC_REQBUFS: u64 = ioc(READ_WRITE, 8, 20);
const VIDIOC_QUERYBUF: u64 = ioc(READ_WRITE, 9, 88);
const VIDIOC_QBUF: u64 = ioc(READ_WRITE, 15, 88);
const VIDIOC_DQBUF: u64 = ioc(READ_WRITE, 17, 88);
const VIDIOC_STREAMON: u64 = ioc(WRITE, 18, 4);
const VIDIOC_G_CTRL: u64 = ioc(READ_WRITE, 27, 8);
const VIDIOC_S_CTRL: u64 = ioc(READ_WRITE, 28, 8);
const VIDIOC_QUERYCTRL: u64 = ioc(READ_WRITE, 36, 68);
const VIDIOC_G_EXT_CTRLS: u64 = ioc(READ_WRITE, 71, 32);

const BUF_TYPE_VIDEO_CAPTURE: u32 = 1;
const MEMORY_MMAP: u32 = 1;
/// Cached buffers, synced for the CPU at each dequeue: the default mapping is
/// uncached, which makes reading a frame several times slower.
const MEMORY_FLAG_NON_COHERENT: u8 = 1;
const PIX_FMT_SRGGB10: u32 = u32::from_le_bytes(*b"RG10");

pub const CID_EXPOSURE: u32 = 0x0098_0911;
pub const CID_VBLANK: u32 = 0x009e_0901;
pub const CID_HBLANK: u32 = 0x009e_0902;
pub const CID_ANALOGUE_GAIN: u32 = 0x009e_0903;
pub const CID_PIXEL_RATE: u32 = 0x009f_0902;

#[repr(C)]
struct PixFormat {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    private: u32,
    flags: u32,
    ycbcr_enc: u32,
    quantization: u32,
    xfer_func: u32,
}

#[repr(C, align(8))]
struct Format {
    kind: u32,
    _pad: u32,
    pix: PixFormat,
    _rest: [u8; 200 - 48],
}

#[repr(C)]
struct RequestBuffers {
    count: u32,
    kind: u32,
    memory: u32,
    capabilities: u32,
    flags: u8,
    _reserved: [u8; 3],
}

#[repr(C)]
struct Buffer {
    index: u32,
    kind: u32,
    bytesused: u32,
    flags: u32,
    field: u32,
    _pad: u32,
    tv_sec: i64,
    tv_usec: i64,
    _timecode: [u32; 4],
    sequence: u32,
    memory: u32,
    offset: u64,
    length: u32,
    _reserved2: u32,
    _request_fd: u32,
    _pad2: u32,
}

#[repr(C)]
struct Control {
    id: u32,
    value: i32,
}

#[repr(C)]
struct QueryControl {
    id: u32,
    kind: u32,
    name: [u8; 32],
    minimum: i32,
    maximum: i32,
    step: i32,
    default_value: i32,
    flags: u32,
    _reserved: [u32; 2],
}

#[repr(C, packed)]
struct ExtControl {
    id: u32,
    size: u32,
    _reserved2: u32,
    value64: i64,
}

#[repr(C)]
struct ExtControls {
    which: u32,
    count: u32,
    error_idx: u32,
    request_fd: i32,
    _reserved: u32,
    _pad: u32,
    controls: *mut ExtControl,
}

fn xioctl<T>(fd: i32, request: u64, arg: &mut T) -> io::Result<()> {
    loop {
        // SAFETY: `arg` is the struct the request's size encodes.
        if unsafe { libc::ioctl(fd, request as _, arg as *mut T) } == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINTR) {
            return Err(error);
        }
    }
}

fn zeroed<T>() -> T {
    // SAFETY: only used for the plain-data ioctl structs above.
    unsafe { std::mem::zeroed() }
}

/// The `/dev` path of the V4L2 node whose sysfs name is `name`.
/// `node_named`, waiting up to `timeout` for a node the kernel has not
/// registered yet, as when the program starts while the sensors still probe.
pub fn wait_for_node(name: &str, timeout: std::time::Duration) -> io::Result<String> {
    retry(timeout, std::time::Duration::from_millis(200), || {
        node_named(name)
    })
}

/// Calls `attempt` until it is not `NotFound` or `timeout` has passed.
pub fn retry<T>(
    timeout: std::time::Duration,
    interval: std::time::Duration,
    mut attempt: impl FnMut() -> io::Result<T>,
) -> io::Result<T> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match attempt() {
            Err(error)
                if error.kind() == io::ErrorKind::NotFound
                    && std::time::Instant::now() < deadline =>
            {
                std::thread::sleep(interval)
            }
            result => return result,
        }
    }
}

pub fn node_named(name: &str) -> io::Result<String> {
    for entry in fs::read_dir("/sys/class/video4linux")? {
        let entry = entry?;
        if fs::read_to_string(entry.path().join("name"))?.trim() == name {
            return Ok(format!("/dev/{}", entry.file_name().to_string_lossy()));
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("no V4L2 node named {name}"),
    ))
}

/// An open video or subdevice node, closed on drop.
pub struct Node {
    pub fd: i32,
}

impl Node {
    pub fn open(path: &str) -> io::Result<Node> {
        let c_path =
            CString::new(path).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        // SAFETY: a NUL-terminated path.
        let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDWR | libc::O_NONBLOCK) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Node { fd })
    }

    pub fn control(&self, id: u32) -> io::Result<i32> {
        let mut control = Control { id, value: 0 };
        xioctl(self.fd, VIDIOC_G_CTRL, &mut control)?;
        Ok(control.value)
    }

    pub fn set_control(&self, id: u32, value: i32) -> io::Result<()> {
        xioctl(self.fd, VIDIOC_S_CTRL, &mut Control { id, value })
    }

    /// `(minimum, maximum)` of a control.
    pub fn control_range(&self, id: u32) -> io::Result<(i32, i32)> {
        let mut query: QueryControl = zeroed();
        query.id = id;
        xioctl(self.fd, VIDIOC_QUERYCTRL, &mut query)?;
        Ok((query.minimum, query.maximum))
    }

    pub fn control64(&self, id: u32) -> io::Result<i64> {
        let mut control = ExtControl {
            id,
            size: 0,
            _reserved2: 0,
            value64: 0,
        };
        let mut controls = ExtControls {
            which: 0,
            count: 1,
            error_idx: 0,
            request_fd: 0,
            _reserved: 0,
            _pad: 0,
            controls: &mut control,
        };
        xioctl(self.fd, VIDIOC_G_EXT_CTRLS, &mut controls)?;
        Ok(control.value64)
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        // SAFETY: the fd is owned by this node.
        unsafe { libc::close(self.fd) };
    }
}

/// A capture node streaming raw 10-bit RGGB into mmapped buffers.
pub struct Capture {
    pub node: Node,
    buffers: Vec<(*mut libc::c_void, usize)>,
}

/// A dequeued frame: its buffer index and the frame start in CLOCK_MONOTONIC ns.
pub struct Dequeued {
    pub index: u32,
    pub start_ns: i64,
    pub bytes: usize,
}

impl Capture {
    /// Sets `width` x `height` RG10 on `node`, maps `count` buffers and starts streaming.
    pub fn start(node: Node, width: u32, height: u32, count: u32) -> io::Result<Capture> {
        let mut format: Format = zeroed();
        format.kind = BUF_TYPE_VIDEO_CAPTURE;
        format.pix.width = width;
        format.pix.height = height;
        format.pix.pixelformat = PIX_FMT_SRGGB10;
        xioctl(node.fd, VIDIOC_S_FMT, &mut format)?;
        if (format.pix.width, format.pix.height, format.pix.pixelformat)
            != (width, height, PIX_FMT_SRGGB10)
        {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                format!(
                    "asked for {width}x{height} RG10, the sensor gives {}x{}",
                    format.pix.width, format.pix.height
                ),
            ));
        }

        let mut request = RequestBuffers {
            count,
            kind: BUF_TYPE_VIDEO_CAPTURE,
            memory: MEMORY_MMAP,
            capabilities: 0,
            flags: MEMORY_FLAG_NON_COHERENT,
            _reserved: [0; 3],
        };
        xioctl(node.fd, VIDIOC_REQBUFS, &mut request)?;

        let mut capture = Capture {
            node,
            buffers: Vec::new(),
        };
        for index in 0..request.count {
            let mut buffer = capture.buffer(index);
            xioctl(capture.node.fd, VIDIOC_QUERYBUF, &mut buffer)?;
            // SAFETY: maps the driver's buffer at the offset it reported.
            let address = unsafe {
                libc::mmap(
                    ptr::null_mut(),
                    buffer.length as usize,
                    libc::PROT_READ,
                    libc::MAP_SHARED,
                    capture.node.fd,
                    buffer.offset as libc::off_t,
                )
            };
            if address == libc::MAP_FAILED {
                return Err(io::Error::last_os_error());
            }
            capture.buffers.push((address, buffer.length as usize));
            capture.queue(index)?;
        }
        let mut kind = BUF_TYPE_VIDEO_CAPTURE as i32;
        xioctl(capture.node.fd, VIDIOC_STREAMON, &mut kind)?;
        Ok(capture)
    }

    fn buffer(&self, index: u32) -> Buffer {
        let mut buffer: Buffer = zeroed();
        buffer.index = index;
        buffer.kind = BUF_TYPE_VIDEO_CAPTURE;
        buffer.memory = MEMORY_MMAP;
        buffer
    }

    pub fn queue(&self, index: u32) -> io::Result<()> {
        xioctl(self.node.fd, VIDIOC_QBUF, &mut self.buffer(index))
    }

    /// The next filled buffer, or `None` when none is ready.
    pub fn dequeue(&self) -> io::Result<Option<Dequeued>> {
        let mut buffer = self.buffer(0);
        match xioctl(self.node.fd, VIDIOC_DQBUF, &mut buffer) {
            Ok(()) => Ok(Some(Dequeued {
                index: buffer.index,
                start_ns: buffer.tv_sec * 1_000_000_000 + buffer.tv_usec * 1_000,
                bytes: buffer.bytesused as usize,
            })),
            Err(e) if e.raw_os_error() == Some(libc::EAGAIN) => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub fn pixels(&self, frame: &Dequeued) -> &[u8] {
        let (address, length) = self.buffers[frame.index as usize];
        // SAFETY: the buffer stays mapped for the life of `self` and the driver
        // does not write to it until it is queued again.
        unsafe { std::slice::from_raw_parts(address as *const u8, frame.bytes.min(length)) }
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        for (address, length) in &self.buffers {
            // SAFETY: each mapping was made in `start` with this length.
            unsafe { libc::munmap(*address, *length) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn retry_waits_for_a_node_that_appears() {
        let mut calls = 0;
        let found = retry(Duration::from_secs(1), Duration::from_millis(1), || {
            calls += 1;
            if calls < 3 {
                Err(io::Error::new(io::ErrorKind::NotFound, "not yet"))
            } else {
                Ok(calls)
            }
        });
        assert_eq!(found.unwrap(), 3);
    }

    #[test]
    fn retry_gives_up_after_the_timeout_and_on_other_errors() {
        let missing: io::Result<()> =
            retry(Duration::from_millis(5), Duration::from_millis(1), || {
                Err(io::Error::new(io::ErrorKind::NotFound, "never"))
            });
        assert_eq!(missing.unwrap_err().kind(), io::ErrorKind::NotFound);

        let mut calls = 0;
        let denied: io::Result<()> =
            retry(Duration::from_secs(1), Duration::from_millis(1), || {
                calls += 1;
                Err(io::Error::new(io::ErrorKind::PermissionDenied, "no"))
            });
        assert_eq!(denied.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(calls, 1);
    }
}
