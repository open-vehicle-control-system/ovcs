//! The Hailo-8 through HailoRT's C API: one vdevice, scheduled round robin, on which each
//! HEF is configured as a network fed one frame at a time from its own thread, through its
//! own page-aligned input and output buffers. A HEF whose frames need no conversion
//! (`direct::takes_direct`) moves them by DMA straight between those buffers and the device,
//! on async streams; any other goes through one input and one output vstream, which convert.

use std::ffi::CString;
use std::mem::MaybeUninit;
use std::ptr;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::direct::{self, Order, PageBuffer};
use crate::outcome::FrameOutcome;

#[allow(
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    dead_code,
    clippy::all
)]
mod ffi {
    include!(concat!(env!("OUT_DIR"), "/hailort.rs"));
}

use ffi::*;

pub use ffi::{HAILO_FORMAT_TYPE_FLOAT32, HAILO_FORMAT_TYPE_UINT8};

extern "C" {
    fn sysconf(name: i32) -> i64;
}

/// Linux's `_SC_PAGESIZE`.
const SC_PAGESIZE: i32 = 30;

/// How long a direct frame's transfers may take, as long as a vstream's.
const TRANSFER_TIMEOUT: Duration = Duration::from_millis(HAILO_DEFAULT_VSTREAM_TIMEOUT_MS as u64);

pub struct InferFailure {
    pub message: String,
    pub outcome: FrameOutcome,
}

fn check(status: hailo_status, what: &str) -> Result<(), String> {
    if status == HAILO_SUCCESS {
        Ok(())
    } else {
        Err(format!("{what} failed: {status}"))
    }
}

/// The accelerator, opened once for every network the program runs.
pub struct Device {
    vdevice: hailo_vdevice,
}

// SAFETY: HailoRT's vdevice is thread-safe; each network's streams are used from one thread.
unsafe impl Send for Device {}
unsafe impl Sync for Device {}

impl Device {
    /// The scheduler activates each network in turn, so several share the device.
    pub fn open() -> Result<Arc<Device>, String> {
        let mut device = Device {
            vdevice: ptr::null_mut(),
        };
        // SAFETY: the params are initialised by HailoRT before use; the handle is released in Drop.
        unsafe {
            let mut params = MaybeUninit::<hailo_vdevice_params_t>::zeroed();
            check(
                hailo_init_vdevice_params(params.as_mut_ptr()),
                "hailo_init_vdevice_params",
            )?;
            (*params.as_mut_ptr()).scheduling_algorithm = HAILO_SCHEDULING_ALGORITHM_ROUND_ROBIN;
            check(
                hailo_create_vdevice(params.as_mut_ptr(), &mut device.vdevice),
                "hailo_create_vdevice",
            )?;
        }
        Ok(Arc::new(device))
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        // SAFETY: released once, after every network holding it has been dropped.
        unsafe {
            if !self.vdevice.is_null() {
                hailo_release_vdevice(self.vdevice);
            }
        }
    }
}

/// A stream's shape: height, width and features (channels).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Shape {
    pub height: usize,
    pub width: usize,
    pub features: usize,
}

impl Shape {
    fn of(shape: hailo_3d_image_shape_t) -> Shape {
        Shape {
            height: shape.height as usize,
            width: shape.width as usize,
            features: shape.features as usize,
        }
    }
}

/// How a network's frames reach the device.
enum Io {
    Vstreams {
        inputs: Vec<hailo_input_vstream>,
        outputs: Vec<hailo_output_vstream>,
    },
    /// Async streams on the network's buffers, mapped for DMA once `mapped`; `transfers` is
    /// where their completions land, at an address that stays put.
    Direct {
        input: hailo_input_stream,
        output: hailo_output_stream,
        transfers: Box<Transfers>,
        mapped: (bool, bool),
    },
}

/// The statuses of one frame's write and read, set from HailoRT's callback threads.
#[derive(Default)]
struct Transfers {
    statuses: Mutex<(Option<hailo_status>, Option<hailo_status>)>,
    changed: Condvar,
}

unsafe extern "C" fn on_written(info: *const hailo_stream_write_async_completion_info_t) {
    // SAFETY: HailoRT passes the info of a write whose opaque is the network's `Transfers`.
    let (status, transfers) = unsafe { ((*info).status, &*(*info).opaque.cast::<Transfers>()) };
    transfers
        .statuses
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .0 = Some(status);
    transfers.changed.notify_all();
}

unsafe extern "C" fn on_read(info: *const hailo_stream_read_async_completion_info_t) {
    // SAFETY: as `on_written`, for a read.
    let (status, transfers) = unsafe { ((*info).status, &*(*info).opaque.cast::<Transfers>()) };
    transfers
        .statuses
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .1 = Some(status);
    transfers.changed.notify_all();
}

/// One HEF configured on the device, with the buffers its frames go in and come out of.
pub struct Network {
    hef: hailo_hef,
    io: Io,
    pub input: Shape,
    output_info: hailo_vstream_info_t,
    /// The order of the output frames read into the output buffer.
    output_order: hailo_format_order_t,
    /// Size of one output frame, in bytes.
    pub output_bytes: usize,
    input_buffer: PageBuffer,
    output_buffer: PageBuffer,
    // Released after the streams and the DMA mappings, which it owns.
    device: Arc<Device>,
}

// SAFETY: the streams and buffers are used from the one thread the network is moved to.
unsafe impl Send for Network {}

impl Network {
    /// UINT8 in, row by row, a pixel's channels together; out in `output_format`: FLOAT32 for
    /// an NMS layer's scores and coordinates, UINT8 for an argmax layer's class ids, which a
    /// HEF that takes them as they are moves by DMA.
    pub fn open(
        device: &Arc<Device>,
        hef_path: &str,
        output_format: hailo_format_type_t,
    ) -> Result<Network, String> {
        let path = CString::new(hef_path).map_err(|_| format!("bad HEF path {hef_path}"))?;
        // SAFETY: a plain libc call.
        let page_bytes = usize::try_from(unsafe { sysconf(SC_PAGESIZE) }).unwrap_or(4096);
        let mut network = Network {
            hef: ptr::null_mut(),
            io: Io::Vstreams {
                inputs: Vec::new(),
                outputs: Vec::new(),
            },
            input: Shape {
                height: 0,
                width: 0,
                features: 0,
            },
            // SAFETY: a plain C struct, filled in below before it is read.
            output_info: unsafe { MaybeUninit::zeroed().assume_init() },
            output_order: HAILO_FORMAT_ORDER_AUTO,
            output_bytes: 0,
            input_buffer: PageBuffer::new(0, page_bytes),
            output_buffer: PageBuffer::new(0, page_bytes),
            device: Arc::clone(device),
        };

        // SAFETY: every out-pointer is a live local or a field of `network`, every struct
        // is sized by bindgen from the sysroot header, and handles are released in Drop.
        unsafe {
            check(
                hailo_create_hef_file(&mut network.hef, path.as_ptr()),
                &format!("hailo_create_hef_file({hef_path})"),
            )?;
            let streams = hef_streams(network.hef, hef_path)?;
            let direct = output_format == HAILO_FORMAT_TYPE_UINT8
                && direct::takes_direct(&streams.iter().map(stream_of).collect::<Vec<_>>());

            let mut configure_params = Box::new(MaybeUninit::<hailo_configure_params_t>::zeroed());
            check(
                hailo_init_configure_params_by_vdevice(
                    network.hef,
                    device.vdevice,
                    configure_params.as_mut_ptr(),
                ),
                "hailo_init_configure_params_by_vdevice",
            )?;
            if direct {
                let params = &mut *configure_params.as_mut_ptr();
                let groups = params.network_group_params_count;
                for group in &mut params.network_group_params[..groups] {
                    let count = group.stream_params_by_name_count;
                    for stream in &mut group.stream_params_by_name[..count] {
                        stream.stream_params.flags |= HAILO_STREAM_FLAGS_ASYNC;
                    }
                }
            }

            let mut network_groups: [hailo_configured_network_group;
                HAILO_MAX_NETWORK_GROUPS as usize] =
                [ptr::null_mut(); HAILO_MAX_NETWORK_GROUPS as usize];
            let mut network_group_count = network_groups.len();
            check(
                hailo_configure_vdevice(
                    device.vdevice,
                    network.hef,
                    configure_params.as_mut_ptr(),
                    network_groups.as_mut_ptr(),
                    &mut network_group_count,
                ),
                &format!("hailo_configure_vdevice({hef_path})"),
            )?;
            if network_group_count == 0 {
                return Err(format!(
                    "{hef_path}: hailo_configure_vdevice returned no network group"
                ));
            }
            let network_group = network_groups[0];

            if direct {
                network.open_direct(network_group, &streams, page_bytes, hef_path)?;
            } else {
                network.open_vstreams(network_group, output_format, page_bytes, hef_path)?;
            }
        }

        let expected = network.input.width * network.input.height * network.input.features;
        let frame = network.input_buffer.as_slice().len();
        if frame != expected {
            return Err(format!(
                "{hef_path}: expected a {expected}-byte UINT8 input frame, HailoRT wants {frame}"
            ));
        }
        Ok(network)
    }

    /// The network's streams, made async at configuration, and its buffers, which HailoRT
    /// maps for DMA once.
    ///
    /// # Safety
    /// `network_group` is the network's configured group, its streams flagged async, and
    /// `streams` its HEF's stream infos.
    unsafe fn open_direct(
        &mut self,
        network_group: hailo_configured_network_group,
        streams: &[hailo_stream_info_t],
        page_bytes: usize,
        hef_path: &str,
    ) -> Result<(), String> {
        let (Some(input_info), Some(output_info)) = (
            streams
                .iter()
                .find(|info| info.direction == HAILO_H2D_STREAM),
            streams
                .iter()
                .find(|info| info.direction == HAILO_D2H_STREAM),
        ) else {
            return Err(format!("{hef_path}: no input or no output stream"));
        };
        let mut input = ptr::null_mut();
        check(
            hailo_get_input_stream(network_group, input_info.name.as_ptr(), &mut input),
            "hailo_get_input_stream",
        )?;
        let mut output = ptr::null_mut();
        check(
            hailo_get_output_stream(network_group, output_info.name.as_ptr(), &mut output),
            "hailo_get_output_stream",
        )?;

        self.input = Shape::of(input_info.__bindgen_anon_1.__bindgen_anon_1.shape);
        self.output_info.__bindgen_anon_1.shape =
            output_info.__bindgen_anon_1.__bindgen_anon_1.shape;
        self.output_order = output_info.format.order;
        self.output_bytes = hailo_get_output_stream_frame_size(output);
        self.input_buffer = PageBuffer::new(hailo_get_input_stream_frame_size(input), page_bytes);
        self.output_buffer = PageBuffer::new(self.output_bytes, page_bytes);
        self.io = Io::Direct {
            input,
            output,
            transfers: Box::default(),
            mapped: (false, false),
        };
        check(
            hailo_vdevice_dma_map_buffer(
                self.device.vdevice,
                self.input_buffer.as_mut_ptr().cast(),
                self.input_buffer.as_slice().len(),
                HAILO_DMA_BUFFER_DIRECTION_H2D,
            ),
            "hailo_vdevice_dma_map_buffer (input)",
        )?;
        if let Io::Direct { mapped, .. } = &mut self.io {
            mapped.0 = true;
        }
        check(
            hailo_vdevice_dma_map_buffer(
                self.device.vdevice,
                self.output_buffer.as_mut_ptr().cast(),
                self.output_buffer.as_slice().len(),
                HAILO_DMA_BUFFER_DIRECTION_D2H,
            ),
            "hailo_vdevice_dma_map_buffer (output)",
        )?;
        if let Io::Direct { mapped, .. } = &mut self.io {
            mapped.1 = true;
        }
        Ok(())
    }

    /// The network's one input and one output vstream, and buffers of their frames' size.
    ///
    /// # Safety
    /// `network_group` is the network's configured group.
    unsafe fn open_vstreams(
        &mut self,
        network_group: hailo_configured_network_group,
        output_format: hailo_format_type_t,
        page_bytes: usize,
        hef_path: &str,
    ) -> Result<(), String> {
        let mut input_params: Vec<hailo_input_vstream_params_by_name_t> =
            vec![MaybeUninit::zeroed().assume_init(); HAILO_MAX_STREAMS_COUNT as usize];
        let mut input_count = input_params.len();
        check(
            hailo_make_input_vstream_params(
                network_group,
                true,
                HAILO_FORMAT_TYPE_UINT8,
                input_params.as_mut_ptr(),
                &mut input_count,
            ),
            "hailo_make_input_vstream_params",
        )?;
        let mut output_params: Vec<hailo_output_vstream_params_by_name_t> =
            vec![MaybeUninit::zeroed().assume_init(); HAILO_MAX_STREAMS_COUNT as usize];
        let mut output_count = output_params.len();
        check(
            hailo_make_output_vstream_params(
                network_group,
                false,
                output_format,
                output_params.as_mut_ptr(),
                &mut output_count,
            ),
            "hailo_make_output_vstream_params",
        )?;
        if input_count != 1 {
            return Err(format!(
                "{hef_path}: expected one input vstream, it has {input_count}"
            ));
        }
        if output_count != 1 {
            return Err(format!(
                "{hef_path}: expected one output vstream, it has {output_count}"
            ));
        }
        input_params.truncate(input_count);
        output_params.truncate(output_count);
        if output_format == HAILO_FORMAT_TYPE_FLOAT32 {
            // The layout `detection::nms::decode_nms_by_class` reads.
            output_params[0].params.user_buffer_format.order =
                HAILO_FORMAT_ORDER_HAILO_NMS_BY_CLASS;
        }
        for input_param in &mut input_params {
            input_param.params.timeout_ms = HAILO_DEFAULT_VSTREAM_TIMEOUT_MS;
            input_param.params.queue_size = HAILO_DEFAULT_VSTREAM_QUEUE_SIZE;
        }
        for output_param in &mut output_params {
            output_param.params.timeout_ms = HAILO_DEFAULT_VSTREAM_TIMEOUT_MS;
            output_param.params.queue_size = HAILO_DEFAULT_VSTREAM_QUEUE_SIZE;
        }

        let mut inputs = vec![ptr::null_mut(); input_count];
        check(
            hailo_create_input_vstreams(
                network_group,
                input_params.as_ptr(),
                input_count,
                inputs.as_mut_ptr(),
            ),
            "hailo_create_input_vstreams",
        )?;
        self.io = Io::Vstreams {
            inputs,
            outputs: Vec::new(),
        };
        let mut outputs = vec![ptr::null_mut(); output_count];
        check(
            hailo_create_output_vstreams(
                network_group,
                output_params.as_ptr(),
                output_count,
                outputs.as_mut_ptr(),
            ),
            "hailo_create_output_vstreams",
        )?;
        let (input, output) = (self.vstreams().0[0], outputs[0]);
        if let Io::Vstreams { outputs: held, .. } = &mut self.io {
            *held = outputs;
        }

        let mut input_info = MaybeUninit::<hailo_vstream_info_t>::zeroed();
        check(
            hailo_get_input_vstream_info(input, input_info.as_mut_ptr()),
            "hailo_get_input_vstream_info",
        )?;
        self.input = Shape::of(input_info.assume_init().__bindgen_anon_1.shape);
        let mut input_frame_size = 0;
        check(
            hailo_get_input_vstream_frame_size(input, &mut input_frame_size),
            "hailo_get_input_vstream_frame_size",
        )?;

        let mut output_info = MaybeUninit::<hailo_vstream_info_t>::zeroed();
        check(
            hailo_get_output_vstream_info(output, output_info.as_mut_ptr()),
            "hailo_get_output_vstream_info",
        )?;
        self.output_info = output_info.assume_init();
        let mut output_user_format = MaybeUninit::<hailo_format_t>::zeroed();
        check(
            hailo_get_output_vstream_user_format(output, output_user_format.as_mut_ptr()),
            "hailo_get_output_vstream_user_format",
        )?;
        self.output_order = output_user_format.assume_init().order;
        check(
            hailo_get_output_vstream_frame_size(output, &mut self.output_bytes),
            "hailo_get_output_vstream_frame_size",
        )?;
        self.input_buffer = PageBuffer::new(input_frame_size, page_bytes);
        self.output_buffer = PageBuffer::new(self.output_bytes, page_bytes);
        Ok(())
    }

    fn vstreams(&self) -> (&[hailo_input_vstream], &[hailo_output_vstream]) {
        match &self.io {
            Io::Vstreams { inputs, outputs } => (inputs, outputs),
            Io::Direct { .. } => (&[], &[]),
        }
    }

    /// Whether the frames move by DMA, without a vstream.
    pub fn direct(&self) -> bool {
        matches!(self.io, Io::Direct { .. })
    }

    /// The buffer a frame is written into before `infer`: the input's shape, UINT8.
    pub fn input_mut(&mut self) -> &mut [u8] {
        self.input_buffer.as_mut_slice()
    }

    /// The output of the last frame `infer` answered, `output_bytes` long, page-aligned.
    pub fn output(&self) -> &[u8] {
        self.output_buffer.as_slice()
    }

    /// The classes an NMS output scores; `Err` unless the output is an NMS layer whose frames
    /// are read NMS by class.
    pub fn nms_classes(&self) -> Result<usize, String> {
        let nms = matches!(
            self.output_info.format.order,
            HAILO_FORMAT_ORDER_HAILO_NMS
                | HAILO_FORMAT_ORDER_HAILO_NMS_ON_CHIP
                | HAILO_FORMAT_ORDER_HAILO_NMS_BY_CLASS
        );
        if !nms || self.output_order != HAILO_FORMAT_ORDER_HAILO_NMS_BY_CLASS {
            return Err(format!(
                "expected an NMS output read by class, its order is {}, read as {}",
                self.output_info.format.order, self.output_order
            ));
        }
        // SAFETY: an NMS output's info holds the union's NMS view.
        let classes = unsafe {
            self.output_info
                .__bindgen_anon_1
                .nms_shape
                .number_of_classes
        };
        Ok(classes as usize)
    }

    /// The output's shape, for a network whose output is not an NMS layer.
    pub fn output_shape(&self) -> Shape {
        // SAFETY: the union's shape view, read for a network opened without an NMS output.
        Shape::of(unsafe { self.output_info.__bindgen_anon_1.shape })
    }

    /// The frame in the input buffer through the device, its output into the output buffer.
    ///
    /// A failed write queues nothing: the streams are cleared and stay reusable when that
    /// succeeds (`WriteFailed { streams_cleared: true }`). A failed read leaves a frame that
    /// may still be in flight on the device and could answer the next read, so `ReadFailed`
    /// streams are not reusable and the program must restart.
    ///
    /// Returns the time from the write to the end of the read: the device's work, the
    /// other networks' turns on it and the PCIe transfers.
    pub fn infer(&mut self) -> Result<Duration, InferFailure> {
        let started = Instant::now();
        match &self.io {
            Io::Vstreams { .. } => self.infer_vstreams()?,
            Io::Direct { .. } => self.infer_direct()?,
        }
        Ok(started.elapsed())
    }

    fn infer_vstreams(&mut self) -> Result<(), InferFailure> {
        let (inputs, outputs) = self.vstreams();
        let (input, output) = (inputs[0], outputs[0]);
        let frame = self.input_buffer.as_slice();
        // SAFETY: both buffers outlive the calls and are at least as long as the sizes passed.
        let written = unsafe {
            check(
                hailo_vstream_write_raw_buffer(input, frame.as_ptr().cast(), frame.len()),
                "hailo_vstream_write_raw_buffer",
            )
        };
        if let Err(message) = written {
            return Err(match self.clear() {
                Ok(()) => InferFailure {
                    message,
                    outcome: FrameOutcome::WriteFailed {
                        streams_cleared: true,
                    },
                },
                Err(clear_message) => InferFailure {
                    message: format!("{message}; {clear_message}"),
                    outcome: FrameOutcome::WriteFailed {
                        streams_cleared: false,
                    },
                },
            });
        }
        let output_bytes = self.output_bytes;
        // SAFETY: as above.
        unsafe {
            check(
                hailo_vstream_read_raw_buffer(
                    output,
                    self.output_buffer.as_mut_ptr().cast(),
                    output_bytes,
                ),
                "hailo_vstream_read_raw_buffer",
            )
        }
        .map_err(|message| InferFailure {
            message,
            outcome: FrameOutcome::ReadFailed,
        })
    }

    /// The write and the read queued on the async streams, then waited for: a failed write
    /// queues nothing, anything after it leaves a frame that may still be in flight.
    fn infer_direct(&mut self) -> Result<(), InferFailure> {
        let Io::Direct {
            input,
            output,
            transfers,
            ..
        } = &self.io
        else {
            unreachable!("infer_direct on vstreams");
        };
        let (input, output) = (*input, *output);
        let opaque = ptr::from_ref::<Transfers>(transfers).cast_mut().cast();
        *transfers.statuses.lock().unwrap_or_else(|e| e.into_inner()) = (None, None);
        let in_flight = |message: String| InferFailure {
            message,
            outcome: FrameOutcome::ReadFailed,
        };

        // SAFETY: both buffers are mapped, outlive the transfers (the program exits on a
        // transfer that does not complete) and are the streams' frame sizes; `opaque` is the
        // boxed `Transfers`, which outlives them too.
        unsafe {
            check(
                hailo_stream_write_raw_buffer_async(
                    input,
                    self.input_buffer.as_mut_ptr().cast(),
                    self.input_buffer.as_slice().len(),
                    Some(on_written),
                    opaque,
                ),
                "hailo_stream_write_raw_buffer_async",
            )
            .map_err(|message| InferFailure {
                message,
                outcome: FrameOutcome::WriteFailed {
                    streams_cleared: true,
                },
            })?;
            check(
                hailo_stream_read_raw_buffer_async(
                    output,
                    self.output_buffer.as_mut_ptr().cast(),
                    self.output_bytes,
                    Some(on_read),
                    opaque,
                ),
                "hailo_stream_read_raw_buffer_async",
            )
            .map_err(in_flight)?;
        }

        let statuses = transfers.statuses.lock().unwrap_or_else(|e| e.into_inner());
        let (statuses, waited) = transfers
            .changed
            .wait_timeout_while(statuses, TRANSFER_TIMEOUT, |(written, read)| {
                written.is_none() || read.is_none()
            })
            .unwrap_or_else(|e| e.into_inner());
        if waited.timed_out() {
            return Err(in_flight(format!(
                "the frame's transfers did not complete within {TRANSFER_TIMEOUT:?}"
            )));
        }
        match *statuses {
            (Some(HAILO_SUCCESS), Some(HAILO_SUCCESS)) => Ok(()),
            (written, read) => Err(in_flight(format!(
                "the frame's transfers failed: write {written:?}, read {read:?}"
            ))),
        }
    }

    fn clear(&self) -> Result<(), String> {
        let (inputs, outputs) = self.vstreams();
        // SAFETY: the handle arrays are the live vstreams created in `open`.
        unsafe {
            check(
                hailo_clear_input_vstreams(inputs.as_ptr(), inputs.len()),
                "hailo_clear_input_vstreams",
            )?;
            check(
                hailo_clear_output_vstreams(outputs.as_ptr(), outputs.len()),
                "hailo_clear_output_vstreams",
            )
        }
    }
}

impl Drop for Network {
    fn drop(&mut self) {
        // SAFETY: each handle is released once, streams and mappings before the HEF and the
        // buffers; the device after.
        unsafe {
            match &self.io {
                Io::Vstreams { inputs, outputs } => {
                    if !inputs.is_empty() {
                        hailo_release_input_vstreams(inputs.as_ptr(), inputs.len());
                    }
                    if !outputs.is_empty() {
                        hailo_release_output_vstreams(outputs.as_ptr(), outputs.len());
                    }
                }
                Io::Direct { mapped, .. } => {
                    let mapped = *mapped;
                    if mapped.0 {
                        hailo_vdevice_dma_unmap_buffer(
                            self.device.vdevice,
                            self.input_buffer.as_mut_ptr().cast(),
                            self.input_buffer.as_slice().len(),
                            HAILO_DMA_BUFFER_DIRECTION_H2D,
                        );
                    }
                    if mapped.1 {
                        hailo_vdevice_dma_unmap_buffer(
                            self.device.vdevice,
                            self.output_buffer.as_mut_ptr().cast(),
                            self.output_buffer.as_slice().len(),
                            HAILO_DMA_BUFFER_DIRECTION_D2H,
                        );
                    }
                }
            }
            if !self.hef.is_null() {
                hailo_release_hef(self.hef);
            }
        }
    }
}

/// How the network's frames reach the device, as its ready log says.
pub fn io(network: &Network) -> &'static str {
    if network.direct() {
        "frames by DMA"
    } else {
        "frames through vstreams"
    }
}

/// The HEF's streams, those of its first network group.
///
/// # Safety
/// `hef` is a live HEF handle.
unsafe fn hef_streams(hef: hailo_hef, hef_path: &str) -> Result<Vec<hailo_stream_info_t>, String> {
    let mut streams: Vec<hailo_stream_info_t> =
        vec![MaybeUninit::zeroed().assume_init(); HAILO_MAX_STREAMS_COUNT as usize];
    let mut count = 0;
    check(
        hailo_hef_get_all_stream_infos(
            hef,
            ptr::null(),
            streams.as_mut_ptr(),
            streams.len(),
            &mut count,
        ),
        &format!("hailo_hef_get_all_stream_infos({hef_path})"),
    )?;
    streams.truncate(count);
    Ok(streams)
}

/// What `direct::takes_direct` needs of a stream info.
fn stream_of(info: &hailo_stream_info_t) -> direct::Stream {
    let order = match info.format.order {
        HAILO_FORMAT_ORDER_NHWC => Order::Nhwc,
        HAILO_FORMAT_ORDER_NHW => Order::Nhw,
        _ => Order::Other,
    };
    // SAFETY: the shape view of the union; an NMS stream's is never taken direct.
    let shape = Shape::of(unsafe { info.__bindgen_anon_1.__bindgen_anon_1.shape });
    direct::Stream {
        input: info.direction == HAILO_H2D_STREAM,
        uint8: info.format.type_ == HAILO_FORMAT_TYPE_UINT8,
        order,
        shape_bytes: shape.height * shape.width * shape.features,
        frame_bytes: info.hw_frame_size as usize,
    }
}
