//! A graph's inputs and outputs as QNN describes them, and their binding to an execution's
//! buffers.

use std::ffi::{c_void, CStr};

use crate::ffi::*;

/// A quantised tensor's scale and offset: a value `q` stands for `(q + offset) × scale`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quantisation {
    pub scale: f32,
    pub offset: i32,
}

impl Quantisation {
    /// The value the 8-bit code `q` stands for.
    pub fn real(self, q: u8) -> f32 {
        (i32::from(q) + self.offset) as f32 * self.scale
    }
}

/// A graph input or output: its name, shape, 8-bit quantisation if any, and size.
#[derive(Clone, Debug, PartialEq)]
pub struct Tensor {
    pub name: String,
    pub dimensions: Vec<u32>,
    pub quantisation: Option<Quantisation>,
    /// Whether an element is one unsigned byte, quantised or not.
    pub unsigned_8bit: bool,
    pub bytes: usize,
}

/// How far a pixel value's scale times 255 may be from 1.
const PIXEL_SCALE_TOLERANCE: f32 = 1e-2;

impl Tensor {
    /// Whether the input reads its bytes as the pixel values they are: unquantised, or with
    /// a scale of 1/255 and an offset of 0. `Err` names the quantisation that does not.
    pub fn check_takes_pixel_values(&self) -> Result<(), String> {
        match self.quantisation {
            Some(Quantisation { scale, offset })
                if offset != 0 || (scale * 255.0 - 1.0).abs() > PIXEL_SCALE_TOLERANCE =>
            {
                Err(format!(
                    "input {} has a scale of {scale} and an offset of {offset}, not a scale \
                     of 1/255 and an offset of 0: it is fed pixel values from 0 to 255",
                    self.name
                ))
            }
            _ => Ok(()),
        }
    }
}

/// A graph's inputs or outputs, and QNN's tensor each is described from, in the same order.
#[derive(Default)]
pub(crate) struct Tensors {
    pub(crate) described: Vec<Tensor>,
    pub(crate) raw: Vec<Qnn_Tensor_t>,
}

fn is_unsigned_8bit(data_type: Qnn_DataType_t) -> bool {
    data_type == QNN_DATATYPE_UFIXED_POINT_8 || data_type == QNN_DATATYPE_UINT_8
}

/// The bytes one element of `data_type` takes: QNN encodes its bit width
/// in the low byte, written as decimal digits (0x08, 0x16, 0x32, 0x64).
fn element_bytes(data_type: Qnn_DataType_t) -> Option<usize> {
    match data_type & 0xff {
        0x08 => Some(1),
        0x16 => Some(2),
        0x32 => Some(4),
        0x64 => Some(8),
        _ => None,
    }
}

/// The tensor's version 1 fields, which version 2 begins with.
///
/// # Safety
/// `tensor` is of version 1 or 2.
unsafe fn fields(tensor: &Qnn_Tensor_t) -> &Qnn_TensorV1_t {
    &tensor.__bindgen_anon_1.v1
}

impl Tensor {
    /// # Safety
    /// `raw` is a tensor QNN described, its name and dimensions still allocated.
    pub(crate) unsafe fn from_raw(raw: &Qnn_Tensor_t) -> Result<Tensor, String> {
        if raw.version != QNN_TENSOR_VERSION_1 && raw.version != QNN_TENSOR_VERSION_2 {
            return Err(format!("unknown tensor version {}", raw.version));
        }
        let v1 = fields(raw);
        let name = if v1.name.is_null() {
            String::new()
        } else {
            CStr::from_ptr(v1.name).to_string_lossy().into_owned()
        };
        let dimensions = if v1.dimensions.is_null() {
            Vec::new()
        } else {
            std::slice::from_raw_parts(v1.dimensions, v1.rank as usize).to_vec()
        };
        let element = element_bytes(v1.dataType)
            .ok_or_else(|| format!("{name}: unsupported data type {:#x}", v1.dataType))?;
        let parameters = &v1.quantizeParams;
        let quantisation = match (
            parameters.encodingDefinition,
            parameters.quantizationEncoding,
        ) {
            (QNN_DEFINITION_DEFINED, QNN_QUANTIZATION_ENCODING_SCALE_OFFSET) => {
                let encoding = parameters.__bindgen_anon_1.scaleOffsetEncoding;
                Some(Quantisation {
                    scale: encoding.scale,
                    offset: encoding.offset,
                })
            }
            (QNN_DEFINITION_DEFINED, encoding)
                if encoding != QNN_QUANTIZATION_ENCODING_UNDEFINED =>
            {
                return Err(format!(
                    "{name}: quantisation encoding {encoding} unsupported, only a scale and an offset"
                ));
            }
            _ => None,
        };
        let bytes = dimensions.iter().map(|&d| d as usize).product::<usize>() * element;
        Ok(Tensor {
            name,
            dimensions,
            quantisation,
            unsigned_8bit: is_unsigned_8bit(v1.dataType),
            bytes,
        })
    }
}

impl Tensors {
    /// # Safety
    /// `tensors` is null or points to `count` tensors as `Tensor::from_raw` takes them.
    pub(crate) unsafe fn from_raw(
        tensors: *const Qnn_Tensor_t,
        count: u32,
    ) -> Result<Tensors, String> {
        if tensors.is_null() {
            return Ok(Tensors::default());
        }
        let raw = std::slice::from_raw_parts(tensors, count as usize).to_vec();
        let described = raw
            .iter()
            .map(|raw| Tensor::from_raw(raw))
            .collect::<Result<_, _>>()?;
        Ok(Tensors { described, raw })
    }
}

/// Points QNN's tensors `raw`, the graph's inputs or outputs as `kind` says, which `tensors`
/// describe, each at the buffer of `buffers` in its place.
pub(crate) fn bind(
    kind: &str,
    tensors: &[Tensor],
    raw: &mut [Qnn_Tensor_t],
    buffers: &mut [impl AsMut<[u8]>],
) -> Result<(), String> {
    if buffers.len() != tensors.len() {
        return Err(format!(
            "{} {kind} buffers for the graph's {} {kind}s",
            buffers.len(),
            tensors.len()
        ));
    }
    for ((tensor, raw), buffer) in tensors.iter().zip(raw).zip(buffers.iter_mut()) {
        let buffer = buffer.as_mut();
        if buffer.len() != tensor.bytes {
            return Err(format!(
                "{}: {} bytes for a {}-byte tensor",
                tensor.name,
                buffer.len(),
                tensor.bytes
            ));
        }
        // SAFETY: version 2 begins with version 1's fields, which are plain data.
        let v1 = unsafe { &mut raw.__bindgen_anon_1.v1 };
        v1.memType = QNN_TENSORMEMTYPE_RAW;
        v1.__bindgen_anon_1.clientBuf = Qnn_ClientBuffer_t {
            data: buffer.as_mut_ptr() as *mut c_void,
            dataSize: buffer.len() as u32,
        };
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::ffi::CString;

    use super::*;

    #[test]
    fn element_sizes_follow_the_data_type_low_byte() {
        assert_eq!(element_bytes(QNN_DATATYPE_UFIXED_POINT_8), Some(1));
        assert_eq!(element_bytes(QNN_DATATYPE_FLOAT_32), Some(4));
        assert_eq!(element_bytes(QNN_DATATYPE_INT_16), Some(2));
    }

    #[test]
    fn unsigned_8_bit_types_are_the_quantised_and_the_plain_ones() {
        assert!(is_unsigned_8bit(QNN_DATATYPE_UFIXED_POINT_8));
        assert!(is_unsigned_8bit(QNN_DATATYPE_UINT_8));
        assert!(!is_unsigned_8bit(QNN_DATATYPE_SFIXED_POINT_8));
        assert!(!is_unsigned_8bit(QNN_DATATYPE_INT_8));
        assert!(!is_unsigned_8bit(QNN_DATATYPE_UFIXED_POINT_16));
    }

    /// An unsigned 8-bit tensor named "mask", quantised with `encoding`.
    fn quantised_tensor(encoding: Qnn_QuantizationEncoding_t) -> (Qnn_Tensor_t, CString) {
        let name = CString::new("mask").unwrap();
        // SAFETY: a tensor is plain data, and its zero holds null pointers.
        let mut raw: Qnn_Tensor_t = unsafe { std::mem::zeroed() };
        raw.version = QNN_TENSOR_VERSION_1;
        // SAFETY: the tensor is of version 1.
        let v1 = unsafe { &mut raw.__bindgen_anon_1.v1 };
        v1.name = name.as_ptr();
        v1.dataType = QNN_DATATYPE_UFIXED_POINT_8;
        v1.quantizeParams.encodingDefinition = QNN_DEFINITION_DEFINED;
        v1.quantizeParams.quantizationEncoding = encoding;
        (raw, name)
    }

    #[test]
    fn a_tensor_quantised_with_a_scale_and_an_offset_is_described_with_them() {
        let (mut raw, _name) = quantised_tensor(QNN_QUANTIZATION_ENCODING_SCALE_OFFSET);
        // SAFETY: the tensor is of version 1, and its union holds the scale and offset.
        unsafe {
            let encoding = &mut raw.__bindgen_anon_1.v1.quantizeParams.__bindgen_anon_1;
            encoding.scaleOffsetEncoding.scale = 0.25;
            encoding.scaleOffsetEncoding.offset = -128;
        }
        // SAFETY: the tensor's name outlives the call, and it has no dimensions.
        let described = unsafe { Tensor::from_raw(&raw) }.map(|tensor| tensor.quantisation);
        assert_eq!(
            described,
            Ok(Some(Quantisation {
                scale: 0.25,
                offset: -128
            }))
        );
    }

    #[test]
    fn a_tensor_quantised_otherwise_is_refused() {
        let (raw, _name) = quantised_tensor(QNN_QUANTIZATION_ENCODING_AXIS_SCALE_OFFSET);
        // SAFETY: the tensor's name outlives the call, and it has no dimensions.
        let described = unsafe { Tensor::from_raw(&raw) }.map(|tensor| tensor.quantisation);
        assert_eq!(
            described,
            Err(
                "mask: quantisation encoding 1 unsupported, only a scale and an offset".to_string()
            )
        );
    }

    #[test]
    fn an_execution_takes_one_buffer_of_its_size_per_tensor() {
        let tensor = Tensor {
            name: "scores".to_string(),
            dimensions: vec![4],
            quantisation: None,
            unsigned_8bit: true,
            bytes: 4,
        };
        let tensors = [tensor.clone(), tensor];
        // SAFETY: a tensor is plain data, and its zero holds null pointers.
        let mut raw: [Qnn_Tensor_t; 2] = unsafe { std::mem::zeroed() };
        let (mut first, mut second, mut short) = ([0u8; 4], [0u8; 4], [0u8; 3]);
        assert_eq!(
            bind(
                "output",
                &tensors,
                &mut raw,
                &mut [&mut first[..], &mut second[..]]
            ),
            Ok(())
        );
        for (tensor, buffer) in raw.iter().zip([&first, &second]) {
            // SAFETY: the tensor is of version 1 and `bind` set its client buffer.
            let (memory, client) = unsafe {
                let v1 = &tensor.__bindgen_anon_1.v1;
                (v1.memType, v1.__bindgen_anon_1.clientBuf)
            };
            assert_eq!(memory, QNN_TENSORMEMTYPE_RAW);
            assert_eq!(client.data.cast_const(), buffer.as_ptr().cast());
            assert_eq!(client.dataSize, 4);
        }
        assert_eq!(
            bind("output", &tensors, &mut raw, &mut [&mut first[..]]),
            Err("1 output buffers for the graph's 2 outputs".to_string())
        );
        assert_eq!(
            bind(
                "output",
                &tensors,
                &mut raw,
                &mut [&mut first[..], &mut short[..]]
            ),
            Err("scores: 3 bytes for a 4-byte tensor".to_string())
        );
    }
}
