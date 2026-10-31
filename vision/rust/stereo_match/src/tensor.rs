//! The named tensors a segment reads and fills: the counterpart of the Nx
//! tensors of `VisionCore.Stereo.NxSegment`, row-major, little-endian on the
//! wire.

use std::borrow::Cow;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
pub enum Data {
    U8(Vec<u8>),
    U16(Vec<u16>),
    F32(Vec<f32>),
    S32(Vec<i32>),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Tensor {
    pub shape: Vec<usize>,
    pub data: Data,
}

pub type Tensors = HashMap<String, Tensor>;

/// The wire codes of the element types, as `VisionCore.Stereo.NativeSegment`
/// maps them to Nx types.
const TYPE_U8: u8 = 0;
const TYPE_U16: u8 = 1;
const TYPE_F32: u8 = 2;
const TYPE_S32: u8 = 3;

/// The size on the wire of one element of type `type_code`.
pub fn element_bytes(type_code: u8) -> Result<usize, String> {
    match type_code {
        TYPE_U8 => Ok(1),
        TYPE_U16 => Ok(2),
        TYPE_F32 | TYPE_S32 => Ok(4),
        other => Err(format!("unknown element type {other}")),
    }
}

impl Tensor {
    pub fn new(shape: Vec<usize>, data: Data) -> Tensor {
        Tensor { shape, data }
    }

    pub fn type_code(&self) -> u8 {
        match self.data {
            Data::U8(_) => TYPE_U8,
            Data::U16(_) => TYPE_U16,
            Data::F32(_) => TYPE_F32,
            Data::S32(_) => TYPE_S32,
        }
    }

    /// The tensor from its wire bytes, which must hold exactly `shape`'s
    /// elements.
    pub fn from_bytes(type_code: u8, shape: Vec<usize>, bytes: &[u8]) -> Result<Tensor, String> {
        let elements: usize = shape.iter().product();
        let element_bytes = element_bytes(type_code)?;
        if bytes.len() != elements * element_bytes {
            return Err(format!(
                "a {shape:?} tensor of {element_bytes}-byte elements takes {} bytes, got {}",
                elements * element_bytes,
                bytes.len()
            ));
        }
        let data = match type_code {
            TYPE_U8 => Data::U8(bytes.to_vec()),
            TYPE_U16 => Data::U16(
                bytes
                    .chunks_exact(2)
                    .map(|b| u16::from_le_bytes([b[0], b[1]]))
                    .collect(),
            ),
            TYPE_F32 => Data::F32(
                bytes
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                    .collect(),
            ),
            _ => Data::S32(
                bytes
                    .chunks_exact(4)
                    .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                    .collect(),
            ),
        };
        Ok(Tensor { shape, data })
    }

    /// The elements' wire bytes, borrowed where the CPU is little-endian.
    pub fn bytes(&self) -> Cow<'_, [u8]> {
        match &self.data {
            Data::U8(values) => Cow::Borrowed(values),
            Data::U16(values) => le_bytes(values, |value| value.to_le_bytes()),
            Data::F32(values) => le_bytes(values, |value| value.to_le_bytes()),
            Data::S32(values) => le_bytes(values, |value| value.to_le_bytes()),
        }
    }

    pub fn byte_len(&self) -> usize {
        match &self.data {
            Data::U8(values) => values.len(),
            Data::U16(values) => 2 * values.len(),
            Data::F32(values) => 4 * values.len(),
            Data::S32(values) => 4 * values.len(),
        }
    }
}

/// `values` as little-endian bytes: their memory, on a little-endian CPU.
#[cfg(target_endian = "little")]
fn le_bytes<T: Copy, const N: usize>(
    values: &[T],
    _to_le_bytes: fn(T) -> [u8; N],
) -> Cow<'_, [u8]> {
    // SAFETY: `T` is a plain number of `N` bytes, whose memory is its little-endian bytes.
    Cow::Borrowed(unsafe {
        std::slice::from_raw_parts(values.as_ptr().cast::<u8>(), std::mem::size_of_val(values))
    })
}

#[cfg(not(target_endian = "little"))]
fn le_bytes<T: Copy, const N: usize>(values: &[T], to_le_bytes: fn(T) -> [u8; N]) -> Cow<'_, [u8]> {
    Cow::Owned(
        values
            .iter()
            .flat_map(|&value| to_le_bytes(value))
            .collect(),
    )
}

/// The `u8` image `name`, of `shape`.
pub fn u8_image<'a>(
    tensors: &'a Tensors,
    name: &str,
    shape: [usize; 2],
) -> Result<&'a [u8], String> {
    match tensors.get(name) {
        Some(Tensor {
            shape: found,
            data: Data::U8(values),
        }) if found[..] == shape => Ok(values),
        Some(tensor) => Err(format!(
            "{name} is a {:?} tensor of type {}, expected a {shape:?} u8 image",
            tensor.shape,
            tensor.type_code()
        )),
        None => Err(format!("no {name} among the segment's tensors")),
    }
}

/// The `f32` map `name`, of `shape`.
pub fn f32_map<'a>(
    tensors: &'a Tensors,
    name: &str,
    shape: [usize; 2],
) -> Result<&'a [f32], String> {
    match tensors.get(name) {
        Some(Tensor {
            shape: found,
            data: Data::F32(values),
        }) if found[..] == shape => Ok(values),
        Some(tensor) => Err(format!(
            "{name} is a {:?} tensor of type {}, expected a {shape:?} f32 map",
            tensor.shape,
            tensor.type_code()
        )),
        None => Err(format!("no {name} among the segment's tensors")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_its_bytes() {
        for tensor in [
            Tensor::new(vec![2, 2], Data::U8(vec![1, 2, 3, 255])),
            Tensor::new(vec![3], Data::U16(vec![0, 1000, 65535])),
            Tensor::new(vec![1, 2], Data::F32(vec![-1.0, 2.5])),
            Tensor::new(vec![], Data::S32(vec![-7])),
        ] {
            let bytes = tensor.bytes();
            assert_eq!(bytes.len(), tensor.byte_len());
            let back = Tensor::from_bytes(tensor.type_code(), tensor.shape.clone(), &bytes);
            assert_eq!(back, Ok(tensor));
        }
    }

    #[test]
    fn refuses_bytes_that_do_not_fill_the_shape() {
        assert!(Tensor::from_bytes(2, vec![2, 2], &[0; 15])
            .unwrap_err()
            .contains("takes 16 bytes"));
        assert!(Tensor::from_bytes(9, vec![1], &[0])
            .unwrap_err()
            .contains("unknown element type"));
    }
}
