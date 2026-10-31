//! The requests `VisionCore.Stereo.Matcher` sends and the replies it reads,
//! each one `{:packet, 4}` record, scalars little-endian. A request starts
//! with its kind:
//!
//! * 1, configure: `segment: u32`, the `width`, `height`, `frame_width` and
//!   `frame_height` the stages work with as `u16`, then the member count
//!   (`u8`) and each member's kind (a name) and build settings: a count
//!   (`u8`), then each one's name and `f64` value. Replied to with tag 7.
//! * 2, run: `segment: u32`, the member count (`u8`) and each member's live
//!   inputs: a count (`u8`), then each one's name, value count (`u16`) and
//!   `f32` values; then the entry tensors: a count (`u8`) and each one as a
//!   tensor. Replied to with tag 8, the member count (`u8`) and each
//!   member's time in microseconds (`u32`), then the tensors the members
//!   filled: a count (`u8`) and each one as a tensor.
//! * 3, release: `segment: u32`. Not replied to.
//!
//! A name is its length (`u8`) and its bytes. A tensor is its name, its
//! type (`u8`: 0 `u8`, 1 `u16`, 2 `f32`, 3 `s32`), its rank (`u8`), each
//! dimension (`u32`), and its elements, row-major.
//!
//! A request that cannot be served gets an error log record saying why,
//! then an empty reply.

use std::borrow::Cow;

use crate::segment::{Geometry, Inputs, Options};
use crate::tensor::{self, Tensor, Tensors};

/// Apart from the tags of `framing`'s records, the log record's among them.
pub const TAG_CONFIGURED: u8 = 7;
pub const TAG_OUTPUTS: u8 = 8;

const CONFIGURE: u8 = 1;
const RUN: u8 = 2;
const RELEASE: u8 = 3;

#[derive(Debug, PartialEq)]
pub enum Request {
    Configure {
        segment: u32,
        geometry: Geometry,
        members: Vec<(String, Options)>,
    },
    Run {
        segment: u32,
        inputs: Vec<Inputs>,
        entries: Tensors,
    },
    Release {
        segment: u32,
    },
}

struct Reader<'a> {
    bytes: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], String> {
        if count > self.bytes.len() {
            return Err(format!(
                "the request ends {} bytes early",
                count - self.bytes.len()
            ));
        }
        let (taken, rest) = self.bytes.split_at(count);
        self.bytes = rest;
        Ok(taken)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], String> {
        Ok(self.take(N)?.try_into().unwrap())
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, String> {
        Ok(u16::from_le_bytes(self.array()?))
    }

    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.array()?))
    }

    fn name(&mut self) -> Result<String, String> {
        let length = usize::from(self.u8()?);
        String::from_utf8(self.take(length)?.to_vec()).map_err(|_| "a name is not UTF-8".into())
    }

    fn tensor(&mut self) -> Result<(String, Tensor), String> {
        let name = self.name()?;
        let type_code = self.u8()?;
        let rank = self.u8()?;
        let shape = (0..rank)
            .map(|_| self.u32().map(|dimension| dimension as usize))
            .collect::<Result<Vec<_>, _>>()?;
        let bytes =
            self.take(shape.iter().product::<usize>() * tensor::element_bytes(type_code)?)?;
        Ok((name, Tensor::from_bytes(type_code, shape, bytes)?))
    }
}

pub fn parse(request: &[u8]) -> Result<Request, String> {
    let mut reader = Reader { bytes: request };
    let kind = reader.u8()?;
    let segment = reader.u32()?;
    let request = match kind {
        CONFIGURE => {
            let mut size = || reader.u16().map(usize::from);
            let geometry = Geometry {
                width: size()?,
                height: size()?,
                frame_width: size()?,
                frame_height: size()?,
            };
            let members = (0..reader.u8()?)
                .map(|_| {
                    let kind = reader.name()?;
                    let options = (0..reader.u8()?)
                        .map(|_| Ok((reader.name()?, f64::from_le_bytes(reader.array()?))))
                        .collect::<Result<Options, String>>()?;
                    Ok((kind, options))
                })
                .collect::<Result<Vec<_>, String>>()?;
            Request::Configure {
                segment,
                geometry,
                members,
            }
        }
        RUN => {
            let inputs = (0..reader.u8()?)
                .map(|_| {
                    (0..reader.u8()?)
                        .map(|_| {
                            let name = reader.name()?;
                            let count = usize::from(reader.u16()?);
                            let values = reader
                                .take(4 * count)?
                                .chunks_exact(4)
                                .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                                .collect();
                            Ok((name, values))
                        })
                        .collect::<Result<Inputs, String>>()
                })
                .collect::<Result<Vec<_>, String>>()?;
            let entries = (0..reader.u8()?)
                .map(|_| reader.tensor())
                .collect::<Result<Tensors, String>>()?;
            Request::Run {
                segment,
                inputs,
                entries,
            }
        }
        RELEASE => Request::Release { segment },
        other => return Err(format!("unknown request kind {other}")),
    };
    if reader.bytes.is_empty() {
        Ok(request)
    } else {
        Err(format!("{} bytes follow the request", reader.bytes.len()))
    }
}

fn push_name(out: &mut Vec<u8>, name: &str) {
    out.push(name.len() as u8);
    out.extend_from_slice(name.as_bytes());
}

/// The reply to a run, each member's time then the tensors they filled, in
/// parts to write one after the other: the tensors' elements are borrowed.
pub fn outputs_record<'a>(times_us: &[u32], outputs: &'a [(String, Tensor)]) -> Vec<Cow<'a, [u8]>> {
    let mut head = vec![TAG_OUTPUTS, times_us.len() as u8];
    for time in times_us {
        head.extend_from_slice(&time.to_le_bytes());
    }
    head.push(outputs.len() as u8);
    let mut parts = Vec::with_capacity(1 + 2 * outputs.len());
    for (name, tensor) in outputs {
        push_name(&mut head, name);
        head.push(tensor.type_code());
        head.push(tensor.shape.len() as u8);
        for &dimension in &tensor.shape {
            head.extend_from_slice(&(dimension as u32).to_le_bytes());
        }
        parts.push(Cow::Owned(std::mem::take(&mut head)));
        parts.push(tensor.bytes());
    }
    parts.push(Cow::Owned(head));
    parts.retain(|part| !part.is_empty());
    parts
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tensor::Data;

    fn name(out: &mut Vec<u8>, name: &str) {
        push_name(out, name);
    }

    #[test]
    fn parses_a_configure_request() {
        let mut request = vec![1, 7, 0, 0, 0, 64, 0, 48, 0, 128, 0, 96, 0, 2];
        name(&mut request, "median_filter");
        request.push(1);
        name(&mut request, "kernel_size");
        request.extend_from_slice(&5f64.to_le_bytes());
        name(&mut request, "depth");
        request.push(0);
        assert_eq!(
            parse(&request),
            Ok(Request::Configure {
                segment: 7,
                geometry: Geometry {
                    width: 64,
                    height: 48,
                    frame_width: 128,
                    frame_height: 96
                },
                members: vec![
                    (
                        "median_filter".into(),
                        Options::from([("kernel_size".into(), 5.0)])
                    ),
                    ("depth".into(), Options::new()),
                ],
            })
        );
    }

    #[test]
    fn parses_a_run_request() {
        let mut request = vec![2, 1, 1, 0, 0, 1, 1];
        name(&mut request, "p1");
        request.extend_from_slice(&1u16.to_le_bytes());
        request.extend_from_slice(&8f32.to_le_bytes());
        request.push(1);
        name(&mut request, "left");
        request.extend_from_slice(&[0, 2, 1, 0, 0, 0, 2, 0, 0, 0, 5, 6]);
        assert_eq!(
            parse(&request),
            Ok(Request::Run {
                segment: 257,
                inputs: vec![Inputs::from([("p1".into(), vec![8.0])])],
                entries: Tensors::from([(
                    "left".into(),
                    Tensor::new(vec![1, 2], Data::U8(vec![5, 6]))
                )]),
            })
        );
    }

    #[test]
    fn refuses_short_long_or_unknown_requests() {
        assert!(parse(&[2, 1, 0])
            .unwrap_err()
            .contains("ends 2 bytes early"));
        assert!(parse(&[3, 1, 0, 0, 0, 9])
            .unwrap_err()
            .contains("1 bytes follow"));
        assert!(parse(&[9, 1, 0, 0, 0])
            .unwrap_err()
            .contains("unknown request kind 9"));
        assert_eq!(parse(&[3, 1, 0, 0, 0]), Ok(Request::Release { segment: 1 }));
    }

    #[test]
    fn writes_times_then_tensors() {
        let outputs = vec![(
            "cloud_points".to_string(),
            Tensor::new(vec![], Data::S32(vec![3])),
        )];
        let mut want = vec![8, 1, 10, 0, 0, 0, 1];
        name(&mut want, "cloud_points");
        want.extend_from_slice(&[3, 0, 3, 0, 0, 0]);
        assert_eq!(outputs_record(&[10], &outputs).concat(), want);
    }
}
