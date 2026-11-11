//! The V4L2 ioctls `v4l2_capture` uses, on aarch64/x86_64 Linux layouts.

use std::ffi::CString;
use std::fs;
use std::io;
use std::ptr;

use crate::bayer::Layout;

const fn ioc(direction: u64, number: u64, size: u64) -> u64 {
    (direction << 30) | (size << 16) | ((b'V' as u64) << 8) | number
}
const READ_WRITE: u64 = 3;
const READ: u64 = 2;
const WRITE: u64 = 1;
const VIDIOC_QUERYCAP: u64 = ioc(READ, 0, 104);
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
const BUF_TYPE_VIDEO_CAPTURE_MPLANE: u32 = 9;
const CAP_VIDEO_CAPTURE_MPLANE: u32 = 0x0000_1000;
const CAP_DEVICE_CAPS: u32 = 0x8000_0000;
const MEMORY_MMAP: u32 = 1;
/// Cached buffers, synced for the CPU at each dequeue: the default mapping is
/// uncached, which makes reading a frame several times slower.
const MEMORY_FLAG_NON_COHERENT: u8 = 1;
const BUF_FLAG_ERROR: u32 = 0x0000_0040;
const PIX_FMT_SRGGB10: u32 = u32::from_le_bytes(*b"RG10");
const PIX_FMT_SRGGB10P: u32 = u32::from_le_bytes(*b"pRAA");

pub const CID_EXPOSURE: u32 = 0x0098_0911;
pub const CID_VBLANK: u32 = 0x009e_0901;
pub const CID_HBLANK: u32 = 0x009e_0902;
pub const CID_ANALOGUE_GAIN: u32 = 0x009e_0903;
pub const CID_PIXEL_RATE: u32 = 0x009f_0902;
pub const CID_FOCUS_ABSOLUTE: u32 = 0x009a_090a;

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
struct PlaneFormat {
    sizeimage: u32,
    bytesperline: u32,
    _reserved: [u16; 6],
}

#[repr(C)]
struct PixFormatMplane {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    colorspace: u32,
    plane_fmt: [PlaneFormat; 8],
    num_planes: u8,
    flags: u8,
    ycbcr_enc: u8,
    quantization: u8,
    xfer_func: u8,
    _reserved: [u8; 7],
}

#[repr(C, align(8))]
struct FormatMplane {
    kind: u32,
    _pad: u32,
    pix: PixFormatMplane,
    _rest: [u8; 200 - 192],
}

#[repr(C)]
struct Capability {
    driver: [u8; 16],
    card: [u8; 32],
    bus_info: [u8; 32],
    version: u32,
    capabilities: u32,
    device_caps: u32,
    _reserved: [u32; 3],
}

/// A multiplanar buffer's plane; `mem_offset` is the union `m`.
#[repr(C)]
struct Plane {
    bytesused: u32,
    length: u32,
    mem_offset: u64,
    data_offset: u32,
    _reserved: [u32; 11],
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

fn xioctl<T>(fd: i32, request: u64, argument: &mut T) -> io::Result<()> {
    loop {
        // SAFETY: `argument` is the struct the request's size encodes.
        if unsafe { libc::ioctl(fd, request as _, argument as *mut T) } == 0 {
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

/// Calls `attempt` until it fails with another error than `waiting`, such as
/// `NotFound` for a node not there yet or `ResourceBusy` for a device another
/// process still holds, or until `timeout` has passed.
pub fn retry<T>(
    timeout: std::time::Duration,
    interval: std::time::Duration,
    waiting: io::ErrorKind,
    mut attempt: impl FnMut() -> io::Result<T>,
) -> io::Result<T> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match attempt() {
            Err(error) if error.kind() == waiting && std::time::Instant::now() < deadline => {
                std::thread::sleep(interval)
            }
            finished => return finished,
        }
    }
}

/// The `/dev` path of the V4L2 node whose sysfs name is `name`.
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
        let c_path = CString::new(path)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        // SAFETY: a NUL-terminated path.
        let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDWR | libc::O_NONBLOCK) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Node { fd })
    }

    /// Whether the node captures through the multiplanar API, as CAMSS's do.
    pub fn multiplanar(&self) -> io::Result<bool> {
        let mut capability: Capability = zeroed();
        xioctl(self.fd, VIDIOC_QUERYCAP, &mut capability)?;
        let capabilities = if capability.capabilities & CAP_DEVICE_CAPS != 0 {
            capability.device_caps
        } else {
            capability.capabilities
        };
        Ok(capabilities & CAP_VIDEO_CAPTURE_MPLANE != 0)
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

/// A capture node streaming raw 10-bit RGGB into mmapped buffers, through
/// the single-plane or the multiplanar API, whichever the node offers.
pub struct Capture {
    pub node: Node,
    /// Bytes from one row's start to the next, padding included.
    pub row_stride: usize,
    /// How the node stores the samples, as its format reply says.
    pub layout: Layout,
    height: usize,
    kind: u32,
    buffers: Vec<(*mut libc::c_void, usize)>,
}

/// A dequeued frame: its buffer index, the frame start in CLOCK_MONOTONIC ns,
/// the bytes the driver filled and its flags.
pub struct Dequeued {
    pub index: u32,
    pub start_ns: i64,
    pub bytes: usize,
    flags: u32,
}

/// Whether a frame holds a whole image: not flagged as damaged by the
/// driver, and `bytes` long enough for `height` rows of `row_stride`.
fn complete(flags: u32, bytes: usize, row_stride: usize, height: usize) -> bool {
    flags & BUF_FLAG_ERROR == 0 && bytes >= row_stride * height
}

/// The sample layout of a format reply's pixel format.
fn layout_of(pixelformat: u32) -> Option<Layout> {
    match pixelformat {
        PIX_FMT_SRGGB10 => Some(Layout::Unpacked16),
        PIX_FMT_SRGGB10P => Some(Layout::Packed10),
        _ => None,
    }
}

/// Asks for RG10, then pRAA, through `request`, which returns the pixel
/// format and bytes per row the node set; the first the node keeps decides
/// the layout. A node replaces a format it does not support with another.
fn negotiate(mut request: impl FnMut(u32) -> io::Result<(u32, u32)>) -> io::Result<(Layout, u32)> {
    for asked in [PIX_FMT_SRGGB10, PIX_FMT_SRGGB10P] {
        let (pixelformat, bytesperline) = request(asked)?;
        if let Some(layout) = layout_of(pixelformat).filter(|_| pixelformat == asked) {
            return Ok((layout, bytesperline));
        }
    }
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "the node takes neither RG10 nor pRAA",
    ))
}

/// Asks `node` for `width` x `height` in `pixelformat` and returns the format
/// it sets: its size, pixel format and bytes per row.
fn set_format(
    node: &Node,
    multiplanar: bool,
    width: u32,
    height: u32,
    pixelformat: u32,
) -> io::Result<(u32, u32, u32, u32)> {
    if multiplanar {
        let mut format: FormatMplane = zeroed();
        format.kind = BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        format.pix.width = width;
        format.pix.height = height;
        format.pix.pixelformat = pixelformat;
        format.pix.num_planes = 1;
        xioctl(node.fd, VIDIOC_S_FMT, &mut format)?;
        let pix = &format.pix;
        Ok((
            pix.width,
            pix.height,
            pix.pixelformat,
            pix.plane_fmt[0].bytesperline,
        ))
    } else {
        let mut format: Format = zeroed();
        format.kind = BUF_TYPE_VIDEO_CAPTURE;
        format.pix.width = width;
        format.pix.height = height;
        format.pix.pixelformat = pixelformat;
        xioctl(node.fd, VIDIOC_S_FMT, &mut format)?;
        let pix = &format.pix;
        Ok((pix.width, pix.height, pix.pixelformat, pix.bytesperline))
    }
}

impl Capture {
    /// Sets `width` x `height` raw 10-bit RGGB on `node`, maps `count` buffers
    /// and starts streaming.
    pub fn start(node: Node, width: u32, height: u32, count: u32) -> io::Result<Capture> {
        let multiplanar = node.multiplanar()?;
        let mut set_size = (0, 0);
        let (layout, bytesperline) = negotiate(|pixelformat| {
            let (set_width, set_height, set, bytesperline) =
                set_format(&node, multiplanar, width, height, pixelformat)?;
            set_size = (set_width, set_height);
            Ok((set, bytesperline))
        })?;
        let (set_width, set_height) = set_size;
        let unsupported = |message: String| io::Error::new(io::ErrorKind::Unsupported, message);
        if (set_width, set_height) != (width, height) {
            return Err(unsupported(format!(
                "asked for {width}x{height}, the sensor gives {set_width}x{set_height}"
            )));
        }
        if (bytesperline as usize) < layout.row_bytes(width as usize) {
            return Err(unsupported(format!(
                "{bytesperline} bytes per row for {width} samples as {layout:?}"
            )));
        }

        let kind = if multiplanar {
            BUF_TYPE_VIDEO_CAPTURE_MPLANE
        } else {
            BUF_TYPE_VIDEO_CAPTURE
        };
        let mut request = RequestBuffers {
            count,
            kind,
            memory: MEMORY_MMAP,
            capabilities: 0,
            flags: MEMORY_FLAG_NON_COHERENT,
            _reserved: [0; 3],
        };
        xioctl(node.fd, VIDIOC_REQBUFS, &mut request)?;

        let mut capture = Capture {
            node,
            row_stride: bytesperline as usize,
            layout,
            height: height as usize,
            kind,
            buffers: Vec::new(),
        };
        for index in 0..request.count {
            let (buffer, plane) = capture.buffer_ioctl(VIDIOC_QUERYBUF, index)?;
            let (offset, length) = if multiplanar {
                (plane.mem_offset, plane.length)
            } else {
                (buffer.offset, buffer.length)
            };
            // SAFETY: maps the driver's buffer at the offset it reported.
            let address = unsafe {
                libc::mmap(
                    ptr::null_mut(),
                    length as usize,
                    libc::PROT_READ,
                    libc::MAP_SHARED,
                    capture.node.fd,
                    offset as libc::off_t,
                )
            };
            if address == libc::MAP_FAILED {
                return Err(io::Error::last_os_error());
            }
            capture.buffers.push((address, length as usize));
            capture.queue(index)?;
        }
        let mut stream_kind = kind as i32;
        xioctl(capture.node.fd, VIDIOC_STREAMON, &mut stream_kind)?;
        Ok(capture)
    }

    /// Runs a buffer `request` on buffer `index`, with its plane on a
    /// multiplanar node; returns both as the driver filled them.
    fn buffer_ioctl(&self, request: u64, index: u32) -> io::Result<(Buffer, Plane)> {
        let mut plane: Plane = zeroed();
        let mut buffer: Buffer = zeroed();
        buffer.index = index;
        buffer.kind = self.kind;
        buffer.memory = MEMORY_MMAP;
        if self.kind == BUF_TYPE_VIDEO_CAPTURE_MPLANE {
            buffer.offset = &mut plane as *mut Plane as u64;
            buffer.length = 1;
        }
        xioctl(self.node.fd, request, &mut buffer)?;
        Ok((buffer, plane))
    }

    pub fn queue(&self, index: u32) -> io::Result<()> {
        self.buffer_ioctl(VIDIOC_QBUF, index).map(|_| ())
    }

    /// The next filled buffer, or `None` when none is ready.
    pub fn dequeue(&self) -> io::Result<Option<Dequeued>> {
        match self.buffer_ioctl(VIDIOC_DQBUF, 0) {
            Ok((buffer, plane)) => Ok(Some(Dequeued {
                index: buffer.index,
                start_ns: buffer.tv_sec * 1_000_000_000 + buffer.tv_usec * 1_000,
                bytes: if self.kind == BUF_TYPE_VIDEO_CAPTURE_MPLANE {
                    plane.bytesused as usize
                } else {
                    buffer.bytesused as usize
                },
                flags: buffer.flags,
            })),
            Err(error) if error.raw_os_error() == Some(libc::EAGAIN) => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// Whether `frame` holds a whole, undamaged image.
    pub fn complete(&self, frame: &Dequeued) -> bool {
        complete(frame.flags, frame.bytes, self.row_stride, self.height)
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
    fn the_ioctl_structs_have_the_kernel_sizes() {
        assert_eq!(std::mem::size_of::<Format>(), 208);
        assert_eq!(std::mem::size_of::<FormatMplane>(), 208);
        assert_eq!(std::mem::size_of::<Capability>(), 104);
        assert_eq!(std::mem::size_of::<Plane>(), 64);
        assert_eq!(std::mem::size_of::<Buffer>(), 88);
    }

    #[test]
    fn a_node_that_replaces_rg10_is_asked_for_packed_samples() {
        let rg10 = u32::from_le_bytes(*b"RG10");
        let packed = u32::from_le_bytes(*b"pRAA");
        let uyvy = u32::from_le_bytes(*b"UYVY");
        let mut asked = Vec::new();
        let reply = negotiate(|pixelformat| {
            asked.push(pixelformat);
            Ok(if pixelformat == packed {
                (packed, 1824)
            } else {
                (uyvy, 1456)
            })
        });
        assert_eq!(reply.unwrap(), (Layout::Packed10, 1824));
        assert_eq!(asked, [rg10, packed]);
        assert!(negotiate(|_| Ok((uyvy, 1456))).is_err());
    }

    #[test]
    fn the_format_reply_sets_the_layout() {
        assert_eq!(
            layout_of(u32::from_le_bytes(*b"RG10")),
            Some(Layout::Unpacked16)
        );
        assert_eq!(
            layout_of(u32::from_le_bytes(*b"pRAA")),
            Some(Layout::Packed10)
        );
        assert_eq!(layout_of(u32::from_le_bytes(*b"YUYV")), None);
    }

    #[test]
    fn a_frame_is_complete_with_every_row_and_no_error_flag() {
        assert!(complete(0, 3_072 * 1_080, 3_072, 1_080));
        assert!(complete(0x01, 3_072 * 1_080 + 64, 3_072, 1_080));
    }

    #[test]
    fn a_frame_flagged_as_damaged_or_short_is_not_complete() {
        assert!(!complete(BUF_FLAG_ERROR, 3_072 * 1_080, 3_072, 1_080));
        assert!(!complete(0, 3_072 * 1_079, 3_072, 1_080));
        assert!(!complete(0, 0, 3_072, 1_080));
    }

    #[test]
    fn retry_waits_for_a_busy_device_to_be_released() {
        let mut calls = 0;
        let opened = retry(
            Duration::from_secs(1),
            Duration::from_millis(1),
            io::ErrorKind::ResourceBusy,
            || {
                calls += 1;
                if calls < 3 {
                    Err(io::Error::from_raw_os_error(libc::EBUSY))
                } else {
                    Ok(calls)
                }
            },
        );
        assert_eq!(opened.unwrap(), 3);
    }

    #[test]
    fn retry_waits_for_a_node_that_appears() {
        let mut calls = 0;
        let found = retry(
            Duration::from_secs(1),
            Duration::from_millis(1),
            io::ErrorKind::NotFound,
            || {
                calls += 1;
                if calls < 3 {
                    Err(io::Error::new(io::ErrorKind::NotFound, "not yet"))
                } else {
                    Ok(calls)
                }
            },
        );
        assert_eq!(found.unwrap(), 3);
    }

    #[test]
    fn retry_gives_up_after_the_timeout_and_on_other_errors() {
        let missing: io::Result<()> = retry(
            Duration::from_millis(5),
            Duration::from_millis(1),
            io::ErrorKind::NotFound,
            || Err(io::Error::new(io::ErrorKind::NotFound, "never")),
        );
        assert_eq!(missing.unwrap_err().kind(), io::ErrorKind::NotFound);

        let mut calls = 0;
        let denied: io::Result<()> = retry(
            Duration::from_secs(1),
            Duration::from_millis(1),
            io::ErrorKind::NotFound,
            || {
                calls += 1;
                Err(io::Error::new(io::ErrorKind::PermissionDenied, "no"))
            },
        );
        assert_eq!(denied.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(calls, 1);
    }
}
