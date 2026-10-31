//! The libcamera capture loop, its JPEG encoder and its grey output.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_uchar, c_ulong, c_void, CStr};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::os::fd::{FromRawFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use framing::{
    frame_record, grey_frame_record, metadata_record, LogLevel, Writer, METADATA_FIELDS,
};
use libcamera::camera::{Camera, CameraConfigurationStatus, Orientation, SensorConfiguration};
use libcamera::camera_manager::CameraManager;
use libcamera::control::{ControlEntry, ControlList};
use libcamera::control_value::{ControlType, ControlValue as LibcameraValue};
use libcamera::controls;
use libcamera::framebuffer::AsFrameBuffer;
use libcamera::framebuffer_allocator::FrameBufferAllocator;
use libcamera::geometry::Size;
use libcamera::pixel_format::PixelFormat;
use libcamera::properties;
use libcamera::request::{RequestStatus, ReuseFlag};
use libcamera::stream::StreamRole;

use crate::args::{Args, ExposureMode, Format, SyncMode};
use crate::controls::{coerce, parse_control, ControlKind, TypedValue};
use crate::grey::{luma_len, pack_luma};
use crate::log;

const METADATA_EVERY_FRAMES: u32 = 5;
const JPEG_QUALITY: c_int = 85;
const SYNC_PATIENCE_FRAMES: u32 = 300;
const BUFFER_COUNT: u32 = 4;

const YUV420: PixelFormat = PixelFormat::new(u32::from_le_bytes(*b"YU12"), 0);

const SYNC_READY_FIELD: usize = 6;

// libcamera's rpi sync controls from the sysroot's control_ids.h, which the libcamera crate does not type.
const SYNC_MODE_ID: u32 = 20011;
const SYNC_READY_ID: u32 = 20012;
const SYNC_TIMER_ID: u32 = 20013;
const SYNC_MODE_SERVER: i32 = 1;
const SYNC_MODE_CLIENT: i32 = 2;

/// Points stderr at a pipe and returns its read end, for `forward_stderr`.
pub fn redirect_stderr() -> Option<RawFd> {
    let mut fds = [0 as c_int; 2];
    // SAFETY: plain fd syscalls on fds this function owns.
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            return None;
        }
        libc::dup2(fds[1], libc::STDERR_FILENO);
        libc::close(fds[1]);
    }
    Some(fds[0])
}

/// libcamera writes its own log to stderr: each line becomes a LOG record.
pub fn forward_stderr(read_fd: RawFd, writer: Arc<Writer>) {
    // SAFETY: `read_fd` is the pipe's read end, owned from here on.
    let pipe = unsafe { File::from_raw_fd(read_fd) };
    thread::spawn(move || {
        for line in BufReader::new(pipe).split(b'\n').map_while(Result::ok) {
            let line = String::from_utf8_lossy(&line);
            let level = if line.contains(" ERROR ") || line.contains(" FATAL ") {
                LogLevel::Error
            } else if line.contains(" WARN ") {
                LogLevel::Warning
            } else {
                LogLevel::Info
            };
            log(&writer, level, &format!("libcamera: {line}"));
        }
    });
}

// How long a start waits for libcamera to list the camera: at boot the sensors
// can still be probing when the first capture starts.
const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(10);
const DISCOVERY_RETRY: Duration = Duration::from_millis(500);

/// A camera manager listing `camera_id`, or the last one started once
/// `DISCOVERY_TIMEOUT` has passed, so the caller reports what it lists.
fn camera_manager(camera_id: usize) -> std::io::Result<CameraManager> {
    let deadline = std::time::Instant::now() + DISCOVERY_TIMEOUT;
    loop {
        let manager = CameraManager::new()?;
        if manager.cameras().len() > camera_id || std::time::Instant::now() >= deadline {
            return Ok(manager);
        }
        drop(manager);
        thread::sleep(DISCOVERY_RETRY);
    }
}

/// Captures until stdin closes; the process exit status.
pub fn run(args: &Args, writer: &Arc<Writer>) -> i32 {
    let info = |message: String| log(writer, LogLevel::Info, &message);
    let warning = |message: String| log(writer, LogLevel::Warning, &message);
    let error = |message: String| log(writer, LogLevel::Error, &message);

    let manager = match camera_manager(args.camera_id as usize) {
        Ok(manager) => manager,
        Err(e) => {
            error(format!("CameraManager::start failed ({e})"));
            return 1;
        }
    };
    let cameras = manager.cameras();
    if cameras.is_empty() {
        error("no cameras detected by libcamera".to_string());
        return 1;
    }
    let Some(camera) = cameras.get(args.camera_id as usize) else {
        error(format!(
            "camera_id {} out of range (have {} cameras)",
            args.camera_id,
            cameras.len()
        ));
        return 1;
    };
    let mut camera = match camera.acquire() {
        Ok(camera) => camera,
        Err(_) => {
            error(format!(
                "Camera::acquire failed (camera {})",
                args.camera_id
            ));
            return 1;
        }
    };

    let mut config = match camera.generate_configuration(&[StreamRole::VideoRecording]) {
        Some(config) if config.len() == 1 => config,
        _ => {
            error("generateConfiguration failed".to_string());
            return 1;
        }
    };

    // Rotated in the pipeline: an upside-down sensor gives an upright frame.
    let orientation = match args.rotation {
        0 => Orientation::Rotate0,
        90 => Orientation::Rotate90,
        180 => Orientation::Rotate180,
        270 => Orientation::Rotate270,
        rotation => {
            error(format!(
                "--rotation {rotation} unsupported (use 0/90/180/270)"
            ));
            return 2;
        }
    };
    config.set_orientation(orientation);

    if let Some(mut stream_config) = config.get_mut(0) {
        stream_config.set_size(Size::new(args.width, args.height));
        stream_config.set_pixel_format(YUV420);
        stream_config.set_buffer_count(BUFFER_COUNT);
    }

    if let Some(mode) = args.sensor_mode {
        let mut sensor = SensorConfiguration::new();
        sensor.set_bit_depth(mode.bit_depth);
        sensor.set_output_size(mode.width, mode.height);
        config.set_sensor_configuration(sensor);
    }

    match config.validate() {
        CameraConfigurationStatus::Valid => {}
        CameraConfigurationStatus::Adjusted => {
            let stream_config = config.get(0).expect("one stream configuration");
            let size = stream_config.get_size();
            info(format!(
                "configuration adjusted to {}x{} {}",
                size.width,
                size.height,
                stream_config.get_pixel_format()
            ));
        }
        CameraConfigurationStatus::Invalid => {
            error(match args.sensor_mode {
                Some(mode) => format!(
                    "configuration invalid: no {}x{} {}-bit sensor mode?",
                    mode.width, mode.height, mode.bit_depth
                ),
                None => "configuration invalid".to_string(),
            });
            return 1;
        }
    }
    if config.orientation() != orientation {
        warning(format!(
            "--rotation {} adjusted to {:?}",
            args.rotation,
            config.orientation()
        ));
    }

    let pixel_format = config
        .get(0)
        .expect("one stream configuration")
        .get_pixel_format();
    if pixel_format != YUV420 {
        error(format!(
            "driver refused YUV420 (got {pixel_format}); aborting"
        ));
        return 1;
    }

    if camera.configure(&mut config).is_err() {
        error("Camera::configure failed".to_string());
        return 1;
    }

    let stream_config = config.get(0).expect("one stream configuration");
    let Some(stream) = stream_config.stream() else {
        error("no stream after Camera::configure".to_string());
        return 1;
    };
    let Size {
        width: out_width,
        height: out_height,
    } = stream_config.get_size();
    let y_stride = stream_config.get_stride() as usize;
    // libcamera's YUV420 packs U and V at half the line stride: the I420 layout turbojpeg expects.
    let uv_stride = y_stride / 2;

    let mut allocator = FrameBufferAllocator::new(&camera);
    let buffers = match allocator.alloc(&stream) {
        Ok(buffers) => buffers,
        Err(_) => {
            error("buffer allocation failed".to_string());
            return 1;
        }
    };

    let mut mapper = FdMapper::default();
    let mut views = Vec::new();
    let mut requests = Vec::new();
    for (index, buffer) in buffers.into_iter().enumerate() {
        let view = {
            let planes = buffer.planes();
            if planes.is_empty() {
                error("buffer has no planes".to_string());
                return 1;
            }
            let plane = |i: usize| {
                let plane = planes.get(i).expect("plane in range");
                (plane.fd(), plane.offset().unwrap_or(0), plane.len())
            };
            let mut sync_fds = Vec::new();
            let mut map = |(fd, offset, length): (RawFd, usize, usize)| {
                if !sync_fds.contains(&fd) {
                    sync_fds.push(fd);
                }
                mapper.map_plane(fd, offset, length).map_err(|e| {
                    error(format!("mmap(fd={fd}) failed: {e}"));
                })
            };
            let mapped = if planes.len() >= 3 {
                (|| Ok((map(plane(0))?, map(plane(1))?, map(plane(2))?)))()
            } else {
                // Single-plane dmabuf: Y, U and V at known offsets within it.
                let y_size = y_stride * out_height as usize;
                let uv_size = uv_stride * (out_height as usize / 2);
                let (fd, offset, _) = plane(0);
                // SAFETY: the mapping covers y_size + 2 * uv_size bytes from base.
                map((fd, offset, y_size + 2 * uv_size))
                    .map(|base| unsafe { (base, base.add(y_size), base.add(y_size + uv_size)) })
            };
            let Ok((y, u, v)) = mapped else {
                error("failed to mmap buffer planes".to_string());
                return 1;
            };
            YuvView {
                planes: [y, u, v],
                strides: [y_stride as c_int, uv_stride as c_int, uv_stride as c_int],
                sync_fds,
            }
        };
        views.push(view);

        let Some(mut request) = camera.create_request(Some(index as u64)) else {
            error("createRequest failed".to_string());
            return 1;
        };
        if request.add_buffer(&stream, buffer).is_err() {
            error("addBuffer failed".to_string());
            return 1;
        }
        requests.push(request);
    }

    let mut output = match args.format {
        Format::Jpeg => match JpegEncoder::new(out_width, out_height) {
            Ok(encoder) => Output::Jpeg(encoder),
            Err(message) => {
                error(message);
                return 1;
            }
        },
        Format::Grey => Output::Grey(Vec::with_capacity(out_width as usize * out_height as usize)),
    };

    let control_ids = control_table(&camera);
    // Value order of the METADATA record.
    let metadata_ids: [u32; METADATA_FIELDS] = [
        controls::ExposureTime::ID,
        controls::AnalogueGain::ID,
        controls::DigitalGain::ID,
        controls::LensPosition::ID,
        controls::FrameDuration::ID,
        controls::ColourTemperature::ID,
        SYNC_READY_ID,
        SYNC_TIMER_ID,
    ];

    let mut start_controls = ControlList::new();
    let period_us = 1_000_000 / i64::from(args.fps.max(1));
    let _ = start_controls.set(controls::FrameDurationLimits([period_us, period_us]));

    // The widest crop the sensor mode allows; a mode can itself be a centre crop of the sensor.
    match camera.properties().get::<properties::ScalerCropMaximum>() {
        Ok(max_crop) => {
            let _ = start_controls.set(controls::ScalerCrop(*max_crop));
            info(format!(
                "ScalerCrop set to the sensor mode's full area ({}x{} @ {},{})",
                max_crop.width, max_crop.height, max_crop.x, max_crop.y
            ));
        }
        Err(_) => warning("ScalerCropMaximum unavailable; FoV may be cropped".to_string()),
    }

    if args.sync_mode != SyncMode::Off {
        match camera.controls().count(SYNC_MODE_ID) {
            0 => warning("no camera sync on this pipeline; --sync ignored".to_string()),
            _ => {
                let (value, role) = match args.sync_mode {
                    SyncMode::Server => (SYNC_MODE_SERVER, "server"),
                    _ => (SYNC_MODE_CLIENT, "client"),
                };
                let _ = start_controls.set_raw(SYNC_MODE_ID, LibcameraValue::from(value));
                info(format!("camera sync as {role}"));
            }
        }
    }

    if let Some(mode) = args.exposure_mode {
        let mode = match mode {
            ExposureMode::Normal => controls::AeExposureMode::ExposureNormal,
            ExposureMode::Short => controls::AeExposureMode::ExposureShort,
            ExposureMode::Long => controls::AeExposureMode::ExposureLong,
        };
        let _ = start_controls.set(mode);
        info(format!("auto-exposure mode {}", mode as i32));
    }

    // A stereo calibration holds only while the lens stays put: focus is manual and fixed.
    if let Some(position) = args.lens_position.filter(|p| *p >= 0.0) {
        if camera.controls().count(controls::AfMode::ID) > 0
            && camera.controls().count(controls::LensPosition::ID) > 0
        {
            let _ = start_controls.set(controls::AfMode::Manual);
            let _ = start_controls.set(controls::LensPosition(position));
            info(format!("focus fixed at {position:.2} dioptres"));
        } else {
            warning("no focus control on this sensor; --lens-position ignored".to_string());
        }
    }

    let stop = Arc::new(AtomicBool::new(false));
    let pending = Arc::new(Mutex::new(HashMap::new()));
    spawn_stdin_reader(
        control_ids,
        Arc::clone(&pending),
        Arc::clone(writer),
        Arc::clone(&stop),
    );

    let completed = camera.subscribe_request_completed();
    if camera.start(Some(&start_controls)).is_err() {
        error("Camera::start failed".to_string());
        return 1;
    }
    for request in requests {
        if camera.queue_request(request).is_err() {
            error("initial queueRequest failed".to_string());
            stop.store(true, Ordering::Relaxed);
            break;
        }
    }

    let mut sync_reported = false;
    let mut frames_without_sync = 0;
    let mut frames_since_metadata = 0;
    while !stop.load(Ordering::Relaxed) {
        let mut request = match completed.recv_timeout(Duration::from_millis(50)) {
            Ok(request) => request,
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        if request.status() == RequestStatus::Cancelled {
            continue;
        }
        let Some(view) = views.get(request.cookie() as usize) else {
            continue;
        };
        let metadata = FrameMetadata::read(request.metadata(), &metadata_ids);

        if args.sync_mode != SyncMode::Off && !sync_reported {
            frames_without_sync += 1;
            if metadata.is_present(SYNC_READY_FIELD) && metadata.values[SYNC_READY_FIELD] != 0.0 {
                info(format!(
                    "camera sync established after {frames_without_sync} frames"
                ));
                sync_reported = true;
            } else if frames_without_sync == SYNC_PATIENCE_FRAMES {
                warning(format!(
                    "camera sync not established after {SYNC_PATIENCE_FRAMES} frames"
                ));
            }
        }

        // Sensor timestamp, so stereo pairing sees the true sync offset rather than DMA
        // scheduling jitter; monotonic when the driver has none.
        let capture_ns = metadata.sensor_timestamp.unwrap_or_else(monotonic_ns);

        frames_since_metadata += 1;
        if frames_since_metadata >= METADATA_EVERY_FRAMES {
            frames_since_metadata = 0;
            let record = metadata_record(capture_ns, metadata.present, &metadata.values);
            let _ = writer.write_record(&record);
        }

        // The dmabuf is not cache-coherent: invalidate before the CPU reads what the ISP wrote.
        dmabuf_sync(&view.sync_fds, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
        let record = match &mut output {
            Output::Jpeg(encoder) => encoder
                .encode(view)
                .map(|jpeg| frame_record(out_width as u16, out_height as u16, capture_ns, jpeg))
                .map_err(|message| format!("tjCompressFromYUVPlanes: {message}")),
            Output::Grey(grey) => {
                let (width, height) = (out_width as usize, out_height as usize);
                // SAFETY: the Y plane is mapped for `height` rows `y_stride` apart.
                let luma = unsafe {
                    std::slice::from_raw_parts(view.planes[0], luma_len(width, height, y_stride))
                };
                pack_luma(grey, luma, width, height, y_stride);
                Ok(grey_frame_record(
                    out_width as u16,
                    out_height as u16,
                    capture_ns,
                    grey,
                ))
            }
        };
        dmabuf_sync(&view.sync_fds, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);

        match record {
            Ok(record) => {
                if writer.write_record(&record).is_err() {
                    stop.store(true, Ordering::Relaxed);
                }
            }
            Err(message) => warning(message),
        }

        request.reuse(ReuseFlag::REUSE_BUFFERS);
        for (id, value) in pending.lock().unwrap_or_else(|e| e.into_inner()).drain() {
            let _ = request.controls_mut().set_raw(id, value);
        }
        let _ = camera.queue_request(request);
    }

    let _ = camera.stop();
    drop(completed);
    0
}

/// Every scalar libcamera control by name, with its id and type.
fn control_table(camera: &Camera) -> HashMap<String, (u32, ControlKind)> {
    let mut table = HashMap::new();
    let Some(list) = ControlList::from_info_map(camera.controls()) else {
        return table;
    };
    let Some(ids) = list.id_map().and_then(|map| map.iter()) else {
        return table;
    };
    let mut ids: Vec<_> = ids.map(|(_, id)| id).collect();
    ids.sort_by_key(|id| id.id());
    for id in ids {
        if id.is_array() {
            continue;
        }
        let kind = match id.ty() {
            ControlType::Bool => ControlKind::Bool,
            ControlType::Int32 => ControlKind::Int32,
            ControlType::Int64 => ControlKind::Int64,
            ControlType::Float => ControlKind::Float,
            _ => continue,
        };
        table
            .entry(id.name().to_string())
            .or_insert((id.id(), kind));
    }
    table
}

/// stdin carries the Port's `{:packet, 4}` records, one `Name=value` each; they apply to
/// the next request requeued. EOF, the BEAM closing the Port, stops the capture.
fn spawn_stdin_reader(
    control_ids: HashMap<String, (u32, ControlKind)>,
    pending: Arc<Mutex<HashMap<u32, LibcameraValue>>>,
    writer: Arc<Writer>,
    stop: Arc<AtomicBool>,
) {
    thread::spawn(move || {
        let mut stdin = std::io::stdin().lock();
        while let Ok(Some(record)) = framing::read_record(&mut stdin) {
            let command = String::from_utf8_lossy(&record);
            let resolved = parse_control(&command).ok().and_then(|(name, value)| {
                let (id, kind) = control_ids.get(&name)?;
                Some((*id, coerce(value, *kind)?))
            });
            match resolved {
                Some((id, value)) => {
                    pending
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .insert(id, libcamera_value(value));
                    log(&writer, LogLevel::Info, &format!("control {command}"));
                }
                None => log(
                    &writer,
                    LogLevel::Warning,
                    &format!("control not understood: {command}"),
                ),
            }
        }
        stop.store(true, Ordering::Relaxed);
    });
}

fn libcamera_value(value: TypedValue) -> LibcameraValue {
    match value {
        TypedValue::Bool(v) => v.into(),
        TypedValue::Int32(v) => v.into(),
        TypedValue::Int64(v) => v.into(),
        TypedValue::Float(v) => v.into(),
    }
}

/// What libcamera applied to a frame.
struct FrameMetadata {
    sensor_timestamp: Option<i64>,
    present: u8,
    values: [f64; METADATA_FIELDS],
}

impl FrameMetadata {
    fn read(list: &ControlList, ids: &[u32; METADATA_FIELDS]) -> FrameMetadata {
        let mut metadata = FrameMetadata {
            sensor_timestamp: None,
            present: 0,
            values: [0.0; METADATA_FIELDS],
        };
        for (id, value) in list {
            if id == controls::SensorTimestamp::ID {
                if let LibcameraValue::Int64(v) = &value {
                    metadata.sensor_timestamp = v.first().copied();
                }
            } else if let Some(field) = ids.iter().position(|field_id| *field_id == id) {
                if let Some(v) = scalar(&value) {
                    metadata.values[field] = v;
                    metadata.present |= 1 << field;
                }
            }
        }
        metadata
    }

    fn is_present(&self, field: usize) -> bool {
        self.present & (1 << field) != 0
    }
}

fn scalar(value: &LibcameraValue) -> Option<f64> {
    match value {
        LibcameraValue::Bool(v) => v.first().map(|b| f64::from(u8::from(*b))),
        LibcameraValue::Int32(v) => v.first().map(|i| f64::from(*i)),
        LibcameraValue::Int64(v) => v.first().map(|i| *i as f64),
        LibcameraValue::Float(v) => v.first().map(|f| f64::from(*f)),
        _ => None,
    }
}

fn monotonic_ns() -> i64 {
    let mut now = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `now` is a valid timespec.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut now) };
    now.tv_sec * 1_000_000_000 + now.tv_nsec
}

/// One mmap per dmabuf fd: libcamera often carves several planes out of one buffer.
#[derive(Default)]
struct FdMapper {
    maps: HashMap<RawFd, (*mut c_void, usize)>,
}

impl FdMapper {
    fn map_plane(&mut self, fd: RawFd, offset: usize, length: usize) -> std::io::Result<*const u8> {
        let base = match self.maps.get(&fd) {
            Some((base, _)) => *base,
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
                base
            }
        };
        // SAFETY: offset lies within the mapping of this plane's dmabuf.
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

/// How a frame becomes a record: JPEG-encoded, or its luma packed into a reused buffer.
enum Output {
    Jpeg(JpegEncoder),
    Grey(Vec<u8>),
}

/// Plane pointers of one buffer, resolved once.
struct YuvView {
    planes: [*const u8; 3],
    strides: [c_int; 3],
    sync_fds: Vec<RawFd>,
}

const DMA_BUF_SYNC_READ: u64 = 1;
const DMA_BUF_SYNC_START: u64 = 0;
const DMA_BUF_SYNC_END: u64 = 1 << 2;
// _IOW('b', 0, struct dma_buf_sync)
const DMA_BUF_IOCTL_SYNC: libc::c_ulong = 0x4008_6200;

fn dmabuf_sync(fds: &[RawFd], flags: u64) {
    for fd in fds {
        // Failure ignored: the worst case is one stale cache line.
        // SAFETY: `flags` matches struct dma_buf_sync, a single u64.
        unsafe { libc::ioctl(*fd, DMA_BUF_IOCTL_SYNC as _, &flags) };
    }
}

type TjHandle = *mut c_void;

const TJSAMP_420: c_int = 2;
const TJFLAG_NOREALLOC: c_int = 1024;
const TJFLAG_FASTDCT: c_int = 2048;

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
struct JpegEncoder {
    handle: TjHandle,
    buffer: *mut c_uchar,
    capacity: c_ulong,
    width: c_int,
    height: c_int,
}

impl JpegEncoder {
    fn new(width: u32, height: u32) -> Result<JpegEncoder, String> {
        let (width, height) = (width as c_int, height as c_int);
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
            })
        }
    }

    fn encode(&mut self, view: &YuvView) -> Result<&[u8], String> {
        let mut planes = view.planes;
        let mut size = self.capacity;
        // SAFETY: the planes are mapped for this frame size; NOREALLOC keeps the buffer.
        unsafe {
            let status = tjCompressFromYUVPlanes(
                self.handle,
                planes.as_mut_ptr(),
                self.width,
                view.strides.as_ptr(),
                self.height,
                TJSAMP_420,
                &mut self.buffer,
                &mut size,
                JPEG_QUALITY,
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
