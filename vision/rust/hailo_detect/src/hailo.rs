//! The HEF on the Hailo-8 through HailoRT's C API: one input and one NMS output vstream,
//! created once and fed one frame at a time.

use std::ffi::CString;
use std::mem::MaybeUninit;
use std::ptr;

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

pub struct InferFailure {
    pub message: String,
    pub outcome: FrameOutcome,
}

pub struct Detector {
    vdevice: hailo_vdevice,
    hef: hailo_hef,
    inputs: Vec<hailo_input_vstream>,
    outputs: Vec<hailo_output_vstream>,
    /// Side of the model's square input, in px.
    pub model_size: i32,
    pub class_count: usize,
    /// Host-side size of one NMS output frame.
    pub output_bytes: usize,
}

fn check(status: hailo_status, what: &str) -> Result<(), String> {
    if status == HAILO_SUCCESS {
        Ok(())
    } else {
        Err(format!("{what} failed: {status}"))
    }
}

impl Detector {
    /// Quantised UINT8 in, the model's native input format, so HailoRT does no conversion;
    /// dequantised FLOAT32 out, as the NMS layer emits scores and normalised coordinates.
    pub fn open(hef_path: &str) -> Result<Detector, String> {
        let path = CString::new(hef_path).map_err(|_| format!("bad HEF path {hef_path}"))?;
        let mut detector = Detector {
            vdevice: ptr::null_mut(),
            hef: ptr::null_mut(),
            inputs: Vec::new(),
            outputs: Vec::new(),
            model_size: 0,
            class_count: 0,
            output_bytes: 0,
        };

        // SAFETY: every out-pointer is a live local or a field of `detector`, every struct
        // is sized by bindgen from the sysroot header, and handles are released in Drop.
        unsafe {
            let mut vdevice_params = MaybeUninit::<hailo_vdevice_params_t>::zeroed();
            check(
                hailo_init_vdevice_params(vdevice_params.as_mut_ptr()),
                "hailo_init_vdevice_params",
            )?;
            check(
                hailo_create_vdevice(vdevice_params.as_mut_ptr(), &mut detector.vdevice),
                "hailo_create_vdevice",
            )?;

            check(
                hailo_create_hef_file(&mut detector.hef, path.as_ptr()),
                &format!("hailo_create_hef_file({hef_path})"),
            )?;

            let mut configure_params = Box::new(MaybeUninit::<hailo_configure_params_t>::zeroed());
            check(
                hailo_init_configure_params_by_vdevice(
                    detector.hef,
                    detector.vdevice,
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
                    detector.vdevice,
                    detector.hef,
                    configure_params.as_mut_ptr(),
                    network_groups.as_mut_ptr(),
                    &mut network_group_count,
                ),
                "hailo_configure_vdevice",
            )?;
            if network_group_count == 0 {
                return Err("hailo_configure_vdevice returned no network group".into());
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
                    HAILO_FORMAT_TYPE_FLOAT32,
                    output_params.as_mut_ptr(),
                    &mut output_count,
                ),
                "hailo_make_output_vstream_params",
            )?;
            if input_count == 0 {
                return Err("the HEF has no input vstream".into());
            }
            if output_count != 1 {
                return Err(format!(
                    "expected one NMS output vstream, the HEF has {output_count}"
                ));
            }
            input_params.truncate(input_count);
            output_params.truncate(output_count);
            for p in &mut input_params {
                p.params.timeout_ms = HAILO_DEFAULT_VSTREAM_TIMEOUT_MS;
                p.params.queue_size = HAILO_DEFAULT_VSTREAM_QUEUE_SIZE;
            }
            for p in &mut output_params {
                p.params.timeout_ms = HAILO_DEFAULT_VSTREAM_TIMEOUT_MS;
                p.params.queue_size = HAILO_DEFAULT_VSTREAM_QUEUE_SIZE;
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
            detector.inputs = inputs;
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
            detector.outputs = outputs;

            let mut input_info = MaybeUninit::<hailo_vstream_info_t>::zeroed();
            check(
                hailo_get_input_vstream_info(detector.inputs[0], input_info.as_mut_ptr()),
                "hailo_get_input_vstream_info",
            )?;
            let shape = input_info.assume_init().__bindgen_anon_1.shape;
            if shape.height != shape.width || shape.features != 3 {
                return Err(format!(
                    "expected a square 3-channel input, got {}x{}x{}",
                    shape.width, shape.height, shape.features
                ));
            }
            detector.model_size = shape.width as i32;

            let mut input_frame_size = 0;
            check(
                hailo_get_input_vstream_frame_size(detector.inputs[0], &mut input_frame_size),
                "hailo_get_input_vstream_frame_size",
            )?;
            let expected = shape.width as usize * shape.height as usize * 3;
            if input_frame_size != expected {
                return Err(format!(
                    "expected a {expected}-byte UINT8 RGB input frame, HailoRT wants {input_frame_size}"
                ));
            }

            let mut output_info = MaybeUninit::<hailo_vstream_info_t>::zeroed();
            check(
                hailo_get_output_vstream_info(detector.outputs[0], output_info.as_mut_ptr()),
                "hailo_get_output_vstream_info",
            )?;
            detector.class_count = output_info
                .assume_init()
                .__bindgen_anon_1
                .nms_shape
                .number_of_classes as usize;
            check(
                hailo_get_output_vstream_frame_size(
                    detector.outputs[0],
                    &mut detector.output_bytes,
                ),
                "hailo_get_output_vstream_frame_size",
            )?;
        }

        Ok(detector)
    }

    /// One frame through the input and output vstreams. `input` is a
    /// `model_size`² RGB frame; `output` holds at least `output_bytes`.
    ///
    /// A failed write queues nothing: the vstreams are cleared and stay reusable when
    /// that succeeds (`WriteFailed { streams_cleared: true }`). A failed read leaves a
    /// frame that may still be in flight on the device and could answer the next read,
    /// so `ReadFailed` streams are not reusable and the `Detector` must be dropped.
    pub fn infer(&mut self, input: &[u8], output: &mut [f32]) -> Result<(), InferFailure> {
        assert!(std::mem::size_of_val(output) >= self.output_bytes);
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
                Err(clear) => InferFailure {
                    message: format!("{message}; {clear}"),
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
        })
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

impl Drop for Detector {
    fn drop(&mut self) {
        // SAFETY: each handle is released once, vstreams before the vdevice that owns them.
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
            if !self.vdevice.is_null() {
                hailo_release_vdevice(self.vdevice);
            }
        }
    }
}
