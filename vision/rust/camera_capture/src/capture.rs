//! The libcamera capture loop, its grey output and the JPEG outputs of its
//! ISP output. A limited-range stream's JPEGs are
//! expanded to the full range JFIF holds; its grey frames are not.

use std::collections::HashMap;
use std::ffi::c_int;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use framing::{
    frame_header, grey_frame_header, metadata_record, output_jpeg_header, LogLevel, Requests,
    Writer, METADATA_FIELDS,
};
use libcamera::camera::{
    ActiveCamera, Camera, CameraConfiguration, CameraConfigurationStatus, Orientation,
    SensorConfiguration,
};
use libcamera::camera_manager::CameraManager;
use libcamera::color_space::Range as LibcameraRange;
use libcamera::control::{ControlEntry, ControlList};
use libcamera::control_value::{ControlType, ControlValue as LibcameraValue};
use libcamera::controls;
use libcamera::framebuffer_allocator::FrameBufferAllocator;
use libcamera::geometry::Size;
use libcamera::pixel_format::PixelFormat;
use libcamera::properties;
use libcamera::request::{Request, RequestStatus, ReuseFlag};
use libcamera::stream::{Stream, StreamRole};

use crate::arguments::{Arguments, ExposureMode, Format, OutputSpec, SyncMode};
use crate::controls::{coerce, parse_control, ControlKind, TypedValue};
use crate::dmabuf::{
    dmabuf_sync, map_view, FdMapper, YuvView, DMA_BUF_SYNC_END, DMA_BUF_SYNC_READ,
    DMA_BUF_SYNC_START,
};
use crate::full_range::{self, Range};
use crate::grey::pack_luma;
use crate::jpeg::{JpegEncoder, JpegPlanes};
use crate::schedule::Schedule;
use crate::streams::{self, Role};

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

// How long a start waits for libcamera to list the camera: at boot the sensors
// can still be probing when the first capture starts.
const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(10);
const DISCOVERY_RETRY: Duration = Duration::from_millis(500);

/// A camera manager listing `camera_id`, or the last one started once
/// `DISCOVERY_TIMEOUT` has passed, so the caller reports what it lists.
fn camera_manager(camera_id: usize) -> std::io::Result<CameraManager> {
    let deadline = std::time::Instant::now() + DISCOVERY_TIMEOUT;
    loop {
        // The host closed the Port: a capture left starting would hold the camera.
        framing::host_present()?;
        let manager = CameraManager::new()?;
        if manager.cameras().len() > camera_id || std::time::Instant::now() >= deadline {
            return Ok(manager);
        }
        drop(manager);
        thread::sleep(DISCOVERY_RETRY);
    }
}

/// Captures until stdin closes; the process exit status.
pub fn run(arguments: &Arguments, writer: &Arc<Writer>) -> i32 {
    let info = |message: String| writer.log(LogLevel::Info, &message);
    let warning = |message: String| writer.log(LogLevel::Warning, &message);
    let error = |message: String| writer.log(LogLevel::Error, &message);

    let manager = match camera_manager(arguments.camera_id as usize) {
        Ok(manager) => manager,
        Err(start_error) if start_error.kind() == std::io::ErrorKind::BrokenPipe => return 0,
        Err(start_error) => {
            error(format!("CameraManager::start failed ({start_error})"));
            return 1;
        }
    };
    let cameras = manager.cameras();
    if cameras.is_empty() {
        error("no cameras detected by libcamera".to_string());
        return 1;
    }
    let Some(camera) = cameras.get(arguments.camera_id as usize) else {
        error(format!(
            "camera_id {} out of range (have {} cameras)",
            arguments.camera_id,
            cameras.len()
        ));
        return 1;
    };
    let mut camera = match camera.acquire() {
        Ok(camera) => camera,
        Err(_) => {
            error(format!(
                "Camera::acquire failed (camera {})",
                arguments.camera_id
            ));
            return 1;
        }
    };

    let plan = streams::plan(arguments);
    let roles: Vec<StreamRole> = (plan.streams.iter())
        .map(|stream| match stream.role {
            Role::VideoRecording => StreamRole::VideoRecording,
            Role::ViewFinder => StreamRole::ViewFinder,
        })
        .collect();
    let mut configuration = match camera.generate_configuration(&roles) {
        Some(configuration) if configuration.len() == roles.len() => configuration,
        _ => {
            error(format!("generateConfiguration failed for {roles:?}"));
            return 1;
        }
    };

    // Rotated in the pipeline: an upside-down sensor gives an upright frame.
    let orientation = match arguments.rotation {
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
    configuration.set_orientation(orientation);

    for (index, stream) in plan.streams.iter().enumerate() {
        if let Some(mut stream_configuration) = configuration.get_mut(index) {
            stream_configuration.set_size(Size::new(stream.width, stream.height));
            stream_configuration.set_pixel_format(YUV420);
            stream_configuration.set_buffer_count(BUFFER_COUNT);
        }
    }

    if let Some(mode) = arguments.sensor_mode {
        let mut sensor = SensorConfiguration::new();
        sensor.set_bit_depth(mode.bit_depth);
        sensor.set_output_size(mode.width, mode.height);
        configuration.set_sensor_configuration(sensor);
    }

    let asked: Vec<String> = (0..configuration.len())
        .map(|index| describe_stream(&configuration, index))
        .collect();
    match configuration.validate() {
        CameraConfigurationStatus::Valid => {}
        CameraConfigurationStatus::Adjusted => {
            for (index, asked) in asked.iter().enumerate() {
                info(format!(
                    "configuration adjusted: stream {index} asked as {asked}, now {}",
                    describe_stream(&configuration, index)
                ));
            }
        }
        CameraConfigurationStatus::Invalid => {
            error(match arguments.sensor_mode {
                Some(mode) => format!(
                    "configuration invalid: no {}x{} {}-bit sensor mode?",
                    mode.width, mode.height, mode.bit_depth
                ),
                None => "configuration invalid".to_string(),
            });
            return 1;
        }
    }
    if configuration.orientation() != orientation {
        warning(format!(
            "--rotation {} adjusted to {:?}",
            arguments.rotation,
            configuration.orientation()
        ));
    }

    for index in 0..configuration.len() {
        let pixel_format = configuration
            .get(index)
            .expect("stream configuration")
            .get_pixel_format();
        if pixel_format != YUV420 {
            error(format!(
                "driver refused YUV420 on stream {index} (got {pixel_format}); aborting"
            ));
            return 1;
        }
    }
    // The JPEG outputs' records carry the size asked for; the frames go on without them.
    let mut isp_output_adjusted = false;
    if let Some(index) = plan.isp_output {
        let asked = &plan.streams[index];
        let size = configuration
            .get(index)
            .expect("stream configuration")
            .get_size();
        if (size.width, size.height) != (asked.width, asked.height) {
            error(format!(
                "ISP output adjusted to {}x{} from {}x{}; its outputs are not written",
                size.width, size.height, asked.width, asked.height
            ));
            isp_output_adjusted = true;
        }
    }

    if camera.configure(&mut configuration).is_err() {
        error("Camera::configure failed".to_string());
        return 1;
    }

    let mut configured = Vec::with_capacity(configuration.len());
    for index in 0..configuration.len() {
        let stream_configuration = configuration.get(index).expect("stream configuration");
        let Some(stream) = stream_configuration.stream() else {
            error("no stream after Camera::configure".to_string());
            return 1;
        };
        configured.push(ConfiguredStream {
            stream,
            size: stream_configuration.get_size(),
            stride: stream_configuration.get_stride() as usize,
            range: (stream_configuration.get_color_space())
                .map(|colour_space| colour_space.range.into()),
        });
        info(format!(
            "stream {index} {}: {}",
            describe_stream(&configuration, index),
            match (index == plan.frames, arguments.format) {
                (true, Format::Grey) => "grey frames of its luma as captured",
                _ if full_range::expands(configured[index].range) => {
                    "its JPEGs expanded from limited to full range"
                }
                _ => "its JPEGs as captured",
            }
        ));
    }
    let Size {
        width: output_width,
        height: output_height,
    } = configured[plan.frames].size;
    let y_stride = configured[plan.frames].stride;

    let mut allocator = FrameBufferAllocator::new(&camera);
    let mut stream_buffers = Vec::with_capacity(configured.len());
    for configured_stream in &configured {
        match allocator.alloc(&configured_stream.stream) {
            Ok(buffers) => stream_buffers.push(buffers.into_iter()),
            Err(_) => {
                error("buffer allocation failed".to_string());
                return 1;
            }
        }
    }
    let buffer_count = stream_buffers.iter().map(|buffers| buffers.len()).min();

    let mut mapper = FdMapper::default();
    // Each stream's buffer views, by a request's cookie.
    let mut views: Vec<Vec<YuvView>> = configured.iter().map(|_| Vec::new()).collect();
    let mut requests = Vec::new();
    for index in 0..buffer_count.unwrap_or(0) {
        let Some(mut request) = camera.create_request(Some(index as u64)) else {
            error("createRequest failed".to_string());
            return 1;
        };
        for (stream_index, buffers) in stream_buffers.iter_mut().enumerate() {
            let buffer = buffers.next().expect("a buffer per request");
            let configured_stream = &configured[stream_index];
            match map_view(&mut mapper, &buffer, configured_stream) {
                Ok(view) => views[stream_index].push(view),
                Err(message) => {
                    error(message);
                    return 1;
                }
            }
            if request
                .add_buffer(&configured_stream.stream, buffer)
                .is_err()
            {
                error("addBuffer failed".to_string());
                return 1;
            }
        }
        requests.push(request);
    }

    let mut jpeg_outputs = match jpeg_outputs(arguments) {
        Ok(_) if isp_output_adjusted => Vec::new(),
        Ok(jpeg_outputs) => jpeg_outputs,
        Err(message) => {
            error(message);
            return 1;
        }
    };
    let mut output_schedule = Schedule::new(arguments.outputs_max_hz, arguments.fps);
    if let (Some(index), false) = (plan.isp_output, jpeg_outputs.is_empty()) {
        let isp_output = &plan.streams[index];
        let frames = match arguments.outputs_max_hz {
            0.0 => "every frame".to_string(),
            max_hz => format!("at most {max_hz} frames a second"),
        };
        info(format!(
            "ISP output {}x{}, JPEG outputs {:?}, on {frames}",
            isp_output.width,
            isp_output.height,
            jpeg_outputs
                .iter()
                .map(|output| output.index)
                .collect::<Vec<_>>(),
        ));
    }

    let mut isp_output_planes = plan
        .isp_output
        .map(|index| JpegPlanes::new(&configured[index]));
    let mut output = match arguments.format {
        Format::Jpeg => match JpegEncoder::new(output_width, output_height, JPEG_QUALITY) {
            Ok(encoder) => Output::Jpeg(encoder, JpegPlanes::new(&configured[plan.frames])),
            Err(message) => {
                error(message);
                return 1;
            }
        },
        Format::Grey => Output::Grey(Vec::with_capacity(
            output_width as usize * output_height as usize,
        )),
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
    let period_us = 1_000_000 / i64::from(arguments.fps.max(1));
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

    if arguments.sync_mode != SyncMode::Off {
        match camera.controls().count(SYNC_MODE_ID) {
            0 => warning("no camera sync on this pipeline; --sync ignored".to_string()),
            _ => {
                let (value, role) = match arguments.sync_mode {
                    SyncMode::Server => (SYNC_MODE_SERVER, "server"),
                    _ => (SYNC_MODE_CLIENT, "client"),
                };
                let _ = start_controls.set_raw(SYNC_MODE_ID, LibcameraValue::from(value));
                info(format!("camera sync as {role}"));
            }
        }
    }

    if let Some(mode) = arguments.exposure_mode {
        let mode = match mode {
            ExposureMode::Normal => controls::AeExposureMode::ExposureNormal,
            ExposureMode::Short => controls::AeExposureMode::ExposureShort,
            ExposureMode::Long => controls::AeExposureMode::ExposureLong,
        };
        let _ = start_controls.set(mode);
        info(format!("auto-exposure mode {}", mode as i32));
    }

    // A stereo calibration holds only while the lens stays put: focus is manual and fixed.
    if let Some(position) = arguments.lens_position.filter(|p| *p >= 0.0) {
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
    let stdin_failed = spawn_stdin_reader(
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
    let mut exit_status = 0;
    for request in requests {
        if let Err((_, queue_error)) = camera.queue_request(request) {
            error(format!("initial queueRequest failed ({queue_error})"));
            exit_status = 1;
            stop.store(true, Ordering::Relaxed);
            break;
        }
    }

    let mut sync_reported = false;
    let mut frames_without_sync = 0;
    let mut frames_since_metadata = 0;
    // Acquire: a stop from the stdin reader also brings its failure.
    while !stop.load(Ordering::Acquire) {
        let request = match completed.recv_timeout(Duration::from_millis(50)) {
            Ok(request) => request,
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        if request.status() == RequestStatus::Cancelled {
            if let Err(message) = requeue(&camera, request, &pending) {
                error(message);
                exit_status = 1;
                break;
            }
            continue;
        }
        let buffer_index = request.cookie() as usize;
        let Some(view) = views[plan.frames].get(buffer_index) else {
            continue;
        };
        let metadata = FrameMetadata::read(request.metadata(), &metadata_ids);

        if arguments.sync_mode != SyncMode::Off && !sync_reported {
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
        let (width, height) = (output_width as u16, output_height as u16);
        // The record's header, then its pixels, written as they are.
        let record = match &mut output {
            Output::Jpeg(encoder, planes) => encoder
                .encode(planes.of(view))
                .map(|jpeg| {
                    (
                        frame_header(width, height, capture_ns, jpeg.len()).to_vec(),
                        jpeg,
                    )
                })
                .map_err(|message| format!("tjCompressFromYUVPlanes: {message}")),
            Output::Grey(grey) => {
                let (columns, rows) = (output_width as usize, output_height as usize);
                pack_luma(grey, view.plane(0), columns, rows, y_stride);
                Ok((
                    grey_frame_header(width, height, capture_ns).to_vec(),
                    &grey[..],
                ))
            }
        };
        dmabuf_sync(&view.sync_fds, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);

        match record {
            Ok((header, pixels)) => {
                if writer.write_record_parts(&[&header, pixels]).is_err() {
                    stop.store(true, Ordering::Relaxed);
                }
            }
            Err(message) => warning(message),
        }

        if let (Some(isp_output), Some(planes), false) = (
            plan.isp_output,
            &mut isp_output_planes,
            jpeg_outputs.is_empty(),
        ) {
            if output_schedule.take_if_due(capture_ns) {
                let view = &views[isp_output][buffer_index];
                if write_jpeg_outputs(writer, view, planes, &mut jpeg_outputs, capture_ns).is_err()
                {
                    stop.store(true, Ordering::Relaxed);
                }
            }
        }

        if let Err(message) = requeue(&camera, request, &pending) {
            error(message);
            exit_status = 1;
            break;
        }
    }

    if stdin_failed.load(Ordering::Relaxed) {
        exit_status = 1;
    }
    let _ = camera.stop();
    drop(completed);
    exit_status
}

/// Queues `request` again, with the controls received since the last one.
fn requeue(
    camera: &ActiveCamera,
    mut request: Request,
    pending: &Mutex<HashMap<u32, LibcameraValue>>,
) -> Result<(), String> {
    request.reuse(ReuseFlag::REUSE_BUFFERS);
    for (id, value) in pending.lock().unwrap_or_else(|e| e.into_inner()).drain() {
        let _ = request.controls_mut().set_raw(id, value);
    }
    (camera.queue_request(request))
        .map_err(|(_, queue_error)| format!("queueRequest failed ({queue_error})"))
}

/// Every scalar libcamera control by name, with its id and type.
fn control_table(camera: &Camera) -> HashMap<String, (u32, ControlKind)> {
    let mut table = HashMap::new();
    let Some(control_list) = ControlList::from_info_map(camera.controls()) else {
        return table;
    };
    let Some(ids) = control_list.id_map().and_then(|map| map.iter()) else {
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

/// The longest record taken from the host: a control is a line of text.
const MAX_CONTROL_BYTES: usize = 64 << 10;

/// stdin carries the Port's `{:packet, 4}` records, one `Name=value` each; they apply to
/// the next request requeued. EOF, the BEAM closing the Port, stops the capture; a failed
/// read stops it too, logged, and sets the flag returned.
fn spawn_stdin_reader(
    control_ids: HashMap<String, (u32, ControlKind)>,
    pending: Arc<Mutex<HashMap<u32, LibcameraValue>>>,
    writer: Arc<Writer>,
    stop: Arc<AtomicBool>,
) -> Arc<AtomicBool> {
    let failed = Arc::new(AtomicBool::new(false));
    let read_failed = Arc::clone(&failed);
    thread::spawn(move || {
        let mut requests = Requests::new(std::io::stdin().lock(), MAX_CONTROL_BYTES);
        loop {
            let record = match requests.read() {
                Ok(Some(record)) => record,
                Ok(None) => break,
                Err(error) => {
                    writer.log(LogLevel::Error, &format!("reading a control: {error}"));
                    read_failed.store(true, Ordering::Relaxed);
                    break;
                }
            };
            let command = String::from_utf8_lossy(record);
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
                    writer.log(LogLevel::Info, &format!("control {command}"));
                }
                None => writer.log(
                    LogLevel::Warning,
                    &format!("control not understood: {command}"),
                ),
            }
        }
        stop.store(true, Ordering::Release);
    });
    failed
}

fn libcamera_value(value: TypedValue) -> LibcameraValue {
    match value {
        TypedValue::Bool(flag) => flag.into(),
        TypedValue::Int32(integer) => integer.into(),
        TypedValue::Int64(integer) => integer.into(),
        TypedValue::Float(float) => float.into(),
    }
}

/// What libcamera applied to a frame.
struct FrameMetadata {
    sensor_timestamp: Option<i64>,
    present: u8,
    values: [f64; METADATA_FIELDS],
}

impl FrameMetadata {
    fn read(control_list: &ControlList, ids: &[u32; METADATA_FIELDS]) -> FrameMetadata {
        let mut metadata = FrameMetadata {
            sensor_timestamp: None,
            present: 0,
            values: [0.0; METADATA_FIELDS],
        };
        for (id, value) in control_list {
            if id == controls::SensorTimestamp::ID {
                if let LibcameraValue::Int64(timestamps) = &value {
                    metadata.sensor_timestamp = timestamps.first().copied();
                }
            } else if let Some(field) = ids.iter().position(|field_id| *field_id == id) {
                if let Some(number) = scalar(&value) {
                    metadata.values[field] = number;
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
        LibcameraValue::Bool(values) => values.first().map(|flag| f64::from(u8::from(*flag))),
        LibcameraValue::Int32(values) => values.first().map(|integer| f64::from(*integer)),
        LibcameraValue::Int64(values) => values.first().map(|integer| *integer as f64),
        LibcameraValue::Float(values) => values.first().map(|float| f64::from(*float)),
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

/// A stream as `Camera::configure` set it up.
pub(crate) struct ConfiguredStream {
    stream: Stream,
    pub(crate) size: Size,
    /// Its luma line stride.
    pub(crate) stride: usize,
    /// Its YUV's range; `None` when libcamera reports no colour space.
    pub(crate) range: Option<Range>,
}

impl From<LibcameraRange> for Range {
    fn from(range: LibcameraRange) -> Range {
        match range {
            LibcameraRange::Full => Range::Full,
            LibcameraRange::Limited => Range::Limited,
        }
    }
}

/// A stream's configuration as libcamera prints it, with its stride and colour space.
fn describe_stream(configuration: &CameraConfiguration, index: usize) -> String {
    let stream_configuration = configuration.get(index).expect("stream configuration");
    let colour_space = stream_configuration.get_color_space().map_or_else(
        || "none".to_string(),
        |colour_space| colour_space.to_string(),
    );
    format!(
        "{} stride {} colour space {colour_space}",
        stream_configuration.to_string_repr(),
        stream_configuration.get_stride()
    )
}

/// A JPEG output of the ISP output, written as OUTPUT_JPEG records under its index.
struct JpegOutput {
    index: u8,
    width: u16,
    height: u16,
    encoder: JpegEncoder,
}

fn jpeg_outputs(arguments: &Arguments) -> Result<Vec<JpegOutput>, String> {
    let mut jpeg_outputs = Vec::new();
    for (index, spec) in arguments.outputs.iter().enumerate() {
        if let OutputSpec::Jpeg {
            width,
            height,
            quality,
            ..
        } = *spec
        {
            jpeg_outputs.push(JpegOutput {
                index: index as u8,
                width: width as u16,
                height: height as u16,
                encoder: JpegEncoder::new(width, height, c_int::from(quality))?,
            });
        }
    }
    Ok(jpeg_outputs)
}

/// Encodes the ISP output's frame `view` for each JPEG output and writes its
/// record. An encode that fails is logged and skipped; a write that fails is
/// returned.
fn write_jpeg_outputs(
    writer: &Writer,
    view: &YuvView,
    planes: &mut JpegPlanes,
    jpeg_outputs: &mut [JpegOutput],
    capture_ns: i64,
) -> std::io::Result<()> {
    dmabuf_sync(&view.sync_fds, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
    let planes = planes.of(view);
    let mut written = Ok(());
    for output in jpeg_outputs.iter_mut() {
        match output.encoder.encode(planes) {
            Ok(jpeg) => {
                let header =
                    output_jpeg_header(output.index, output.width, output.height, capture_ns);
                written = writer.write_record_parts(&[&header, jpeg]);
                if written.is_err() {
                    break;
                }
            }
            Err(message) => writer.log(
                LogLevel::Warning,
                &format!("output {} tjCompressFromYUVPlanes: {message}", output.index),
            ),
        }
    }
    dmabuf_sync(&view.sync_fds, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
    written
}

/// How a frame becomes a record: JPEG-encoded, or its luma packed into a reused buffer.
enum Output {
    Jpeg(JpegEncoder, JpegPlanes),
    Grey(Vec<u8>),
}
