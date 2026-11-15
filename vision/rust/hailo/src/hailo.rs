//! The Hailo-8 through HailoRT's C API: one vdevice, scheduled round robin, on which each
//! HEF is configured as a network with one input and one output vstream, fed one frame at a
//! time from its own thread.

use std::ffi::CString;
use std::mem::MaybeUninit;
use std::ptr;
use std::sync::Arc;
use std::time::{Duration, Instant};

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

// SAFETY: HailoRT's vdevice is thread-safe; each network's vstreams are used from one thread.
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

/// A vstream's shape: height, width and features (channels).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Shape {
    pub height: usize,
    pub width: usize,
    pub features: usize,
}

/// One HEF configured on the device, with its input and output vstreams.
pub struct Network {
    hef: hailo_hef,
    inputs: Vec<hailo_input_vstream>,
    outputs: Vec<hailo_output_vstream>,
    pub input: Shape,
    output_info: hailo_vstream_info_t,
    /// Host-side size of one output frame, in bytes.
    pub output_bytes: usize,
    // Released after the vstreams, which it owns.
    _device: Arc<Device>,
}

// SAFETY: the vstreams are used from the one thread the network is moved to.
unsafe impl Send for Network {}

impl Network {
    /// Quantised UINT8 in, the model's native input format, so HailoRT does no conversion;
    /// out in `output_format`: FLOAT32 for an NMS layer's scores and coordinates, UINT8 for
    /// an argmax layer's class ids.
    pub fn open(
        device: &Arc<Device>,
        hef_path: &str,
        output_format: hailo_format_type_t,
    ) -> Result<Network, String> {
        let path = CString::new(hef_path).map_err(|_| format!("bad HEF path {hef_path}"))?;
        let mut network = Network {
            hef: ptr::null_mut(),
            inputs: Vec::new(),
            outputs: Vec::new(),
            input: Shape {
                height: 0,
                width: 0,
                features: 0,
            },
            // SAFETY: a plain C struct, filled in below before it is read.
            output_info: unsafe { MaybeUninit::zeroed().assume_init() },
            output_bytes: 0,
            _device: Arc::clone(device),
        };

        // SAFETY: every out-pointer is a live local or a field of `network`, every struct
        // is sized by bindgen from the sysroot header, and handles are released in Drop.
        unsafe {
            check(
                hailo_create_hef_file(&mut network.hef, path.as_ptr()),
                &format!("hailo_create_hef_file({hef_path})"),
            )?;

            let mut configure_params = Box::new(MaybeUninit::<hailo_configure_params_t>::zeroed());
            check(
                hailo_init_configure_params_by_vdevice(
                    network.hef,
                    device.vdevice,
                    configure_params.as_mut_ptr(),
                ),
                "hailo_init_configure_params_by_vdevice",
            )?;

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
            network.inputs = inputs;
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
            network.outputs = outputs;

            let mut input_info = MaybeUninit::<hailo_vstream_info_t>::zeroed();
            check(
                hailo_get_input_vstream_info(network.inputs[0], input_info.as_mut_ptr()),
                "hailo_get_input_vstream_info",
            )?;
            let shape = input_info.assume_init().__bindgen_anon_1.shape;
            network.input = Shape {
                height: shape.height as usize,
                width: shape.width as usize,
                features: shape.features as usize,
            };

            let mut input_frame_size = 0;
            check(
                hailo_get_input_vstream_frame_size(network.inputs[0], &mut input_frame_size),
                "hailo_get_input_vstream_frame_size",
            )?;
            let expected = network.input.width * network.input.height * network.input.features;
            if input_frame_size != expected {
                return Err(format!(
                    "{hef_path}: expected a {expected}-byte UINT8 input frame, HailoRT wants {input_frame_size}"
                ));
            }

            let mut output_info = MaybeUninit::<hailo_vstream_info_t>::zeroed();
            check(
                hailo_get_output_vstream_info(network.outputs[0], output_info.as_mut_ptr()),
                "hailo_get_output_vstream_info",
            )?;
            network.output_info = output_info.assume_init();
            check(
                hailo_get_output_vstream_frame_size(network.outputs[0], &mut network.output_bytes),
                "hailo_get_output_vstream_frame_size",
            )?;
        }

        Ok(network)
    }

    /// The classes an NMS output scores.
    pub fn nms_classes(&self) -> usize {
        // SAFETY: the union's NMS view, read for a network opened with an NMS output.
        unsafe {
            self.output_info
                .__bindgen_anon_1
                .nms_shape
                .number_of_classes as usize
        }
    }

    /// The output's shape, for a network whose output is not an NMS layer.
    pub fn output_shape(&self) -> Shape {
        // SAFETY: the union's shape view, read for a network opened without an NMS output.
        let shape = unsafe { self.output_info.__bindgen_anon_1.shape };
        Shape {
            height: shape.height as usize,
            width: shape.width as usize,
            features: shape.features as usize,
        }
    }

    /// One frame through the input and output vstreams. `input` is a frame of the input's
    /// shape; `output` holds at least `output_bytes`.
    ///
    /// A failed write queues nothing: the vstreams are cleared and stay reusable when
    /// that succeeds (`WriteFailed { streams_cleared: true }`). A failed read leaves a
    /// frame that may still be in flight on the device and could answer the next read,
    /// so `ReadFailed` streams are not reusable and the program must restart.
    ///
    /// Returns the time from the write to the end of the read: the device's work, the
    /// other networks' turns on it and the PCIe transfers.
    pub fn infer(&mut self, input: &[u8], output: &mut [u8]) -> Result<Duration, InferFailure> {
        assert!(output.len() >= self.output_bytes);
        let started = Instant::now();
        // SAFETY: both buffers outlive the calls and are at least as long as the sizes passed.
        let written = unsafe {
            check(
                hailo_vstream_write_raw_buffer(self.inputs[0], input.as_ptr().cast(), input.len()),
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
        // SAFETY: as above.
        unsafe {
            check(
                hailo_vstream_read_raw_buffer(
                    self.outputs[0],
                    output.as_mut_ptr().cast(),
                    self.output_bytes,
                ),
                "hailo_vstream_read_raw_buffer",
            )
        }
        .map_err(|message| InferFailure {
            message,
            outcome: FrameOutcome::ReadFailed,
        })?;
        Ok(started.elapsed())
    }

    fn clear(&mut self) -> Result<(), String> {
        // SAFETY: the handle arrays are the live vstreams created in `open`.
        unsafe {
            check(
                hailo_clear_input_vstreams(self.inputs.as_ptr(), self.inputs.len()),
                "hailo_clear_input_vstreams",
            )?;
            check(
                hailo_clear_output_vstreams(self.outputs.as_ptr(), self.outputs.len()),
                "hailo_clear_output_vstreams",
            )
        }
    }
}

impl Drop for Network {
    fn drop(&mut self) {
        // SAFETY: each handle is released once, vstreams before the HEF; the device after.
        unsafe {
            if !self.inputs.is_empty() {
                hailo_release_input_vstreams(self.inputs.as_ptr(), self.inputs.len());
            }
            if !self.outputs.is_empty() {
                hailo_release_output_vstreams(self.outputs.as_ptr(), self.outputs.len());
            }
            if !self.hef.is_null() {
                hailo_release_hef(self.hef);
            }
        }
    }
}
