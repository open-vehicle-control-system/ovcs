//! A camera output's video encoder: NV12 frames in, H.264 out. `Encoder` is
//! what the frame loop calls; `M2mEncoder` drives a V4L2 memory-to-memory
//! encoder, such as Qualcomm's Iris, through the ioctls `M2mDevice` stands for.

use std::collections::VecDeque;
use std::fmt;
use std::io;
use std::time::{Duration, Instant};

use crate::nv12::Nv12Layout;

/// One frame of the stream, its NAL units in Annex B form.
#[derive(Clone, Debug, PartialEq)]
pub struct EncodedFrame {
    pub capture_ns: i64,
    pub key_frame: bool,
    pub bytes: Vec<u8>,
    /// From the frame queued to the encoder to its stream dequeued.
    pub took: Duration,
}

/// Encodes a camera output's frames, one at a time, in order.
pub trait Encoder: Send {
    /// The layout of the NV12 frames it takes.
    fn layout(&self) -> Nv12Layout;

    /// Encodes `nv12`, laid out as `layout`, the frame captured at
    /// `capture_ns`: its encoded frame, or `None` when the encoder gave none.
    fn encode(&mut self, nv12: &[u8], capture_ns: i64) -> io::Result<Option<EncodedFrame>>;

    /// Lets the encoder finish what it holds, dropped, and stops it.
    fn stop(&mut self) -> io::Result<()>;
}

/// How an output is encoded.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct H264Settings {
    pub width: u32,
    pub height: u32,
    pub bitrate_kbps: u32,
    /// Frames from one key frame to the next.
    pub keyframe_interval: u32,
    pub fps: u32,
}

/// A memory-to-memory device's two queues: raw frames in, the coded stream out
/// (V4L2's OUTPUT and CAPTURE).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stream {
    Raw,
    Coded,
}

/// What a device sets of a format asked: the size of its buffers' image,
/// its bytes per row and the bytes a buffer holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BufferFormat {
    pub width: u32,
    pub height: u32,
    pub bytes_per_line: u32,
    pub size: u32,
}

/// A buffer dequeued, its flags V4L2's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DequeuedBuffer {
    pub index: u32,
    /// The bytes it holds, from its start, its data from `data_offset`.
    pub bytes_used: usize,
    pub data_offset: usize,
    pub flags: u32,
    /// The timestamp of the raw frame it was made from, to the microsecond.
    pub timestamp_ns: i64,
}

pub const PIX_FMT_NV12: u32 = u32::from_le_bytes(*b"NV12");
pub const PIX_FMT_H264: u32 = u32::from_le_bytes(*b"H264");
pub const BUF_FLAG_KEYFRAME: u32 = 0x0000_0008;
pub const BUF_FLAG_ERROR: u32 = 0x0000_0040;
pub const BUF_FLAG_LAST: u32 = 0x0010_0000;
pub const CID_BITRATE_MODE: u32 = 0x0099_09ce;
pub const CID_BITRATE: u32 = 0x0099_09cf;
pub const CID_GOP_SIZE: u32 = 0x0099_09cb;
pub const CID_B_FRAMES: u32 = 0x0099_09ca;
pub const CID_HEADER_MODE: u32 = 0x0099_09d8;
pub const CID_REPEAT_SEQ_HEADER: u32 = 0x0099_09e2;
pub const CID_PREPEND_SPSPPS_TO_IDR: u32 = 0x0099_0b84;
const BITRATE_MODE_CBR: i32 = 1;
const HEADER_MODE_JOINED_WITH_FIRST_FRAME: i32 = 1;

/// Buffers asked for on each queue; the device may set more.
const BUFFERS: u32 = 4;
/// How long a frame or the drain may take before the encoder counts as stuck, by default.
const ENCODE_TIMEOUT: Duration = Duration::from_secs(1);

/// The ioctls of a V4L2 memory-to-memory encoder.
pub trait M2mDevice: Send {
    /// Asks for `width` x `height` in `pixel_format` on `stream`.
    fn set_format(
        &mut self,
        stream: Stream,
        pixel_format: u32,
        width: u32,
        height: u32,
    ) -> io::Result<BufferFormat>;
    /// Crops the raw frames to their top-left `width` x `height`, the size
    /// encoded; returns the crop set.
    fn set_crop(&mut self, width: u32, height: u32) -> io::Result<(u32, u32)>;
    fn set_frame_rate(&mut self, fps: u32) -> io::Result<()>;
    fn has_control(&self, id: u32) -> bool;
    fn set_control(&mut self, id: u32, value: i32) -> io::Result<()>;
    /// Allocates and maps `count` buffers on `stream`; returns how many it made.
    fn request_buffers(&mut self, stream: Stream, count: u32) -> io::Result<u32>;
    fn raw_buffer(&mut self, index: u32) -> &mut [u8];
    fn coded_buffer(&self, index: u32) -> &[u8];
    /// Queues buffer `index` of `stream`, `bytes_used` filled, stamped `timestamp_ns`.
    fn queue(
        &mut self,
        stream: Stream,
        index: u32,
        bytes_used: usize,
        timestamp_ns: i64,
    ) -> io::Result<()>;
    /// The next buffer `stream` is done with, `None` when none is; a
    /// `BrokenPipe` error once the last of a drain was dequeued.
    fn dequeue(&mut self, stream: Stream) -> io::Result<Option<DequeuedBuffer>>;
    /// Waits up to `timeout` for a buffer to dequeue on `stream`.
    fn wait(&mut self, stream: Stream, timeout: Duration) -> io::Result<()>;
    fn stream_on(&mut self, stream: Stream) -> io::Result<()>;
    fn stream_off(&mut self, stream: Stream) -> io::Result<()>;
    /// Asks the encoder to finish the frames queued and mark the last.
    fn stop_encoding(&mut self) -> io::Result<()>;
}

/// An H.264 encoder over a V4L2 memory-to-memory device.
pub struct M2mEncoder<D: M2mDevice> {
    device: D,
    layout: Nv12Layout,
    free_raw: Vec<u32>,
    /// Each frame queued and not encoded yet: its capture time and when it was queued.
    pending: VecDeque<(i64, Instant)>,
    streaming: bool,
    /// The setup's steps the device did not take.
    skipped: Vec<String>,
    /// How long a frame or the drain may take before the encoder counts as stuck.
    timeout: Duration,
}

impl<D: M2mDevice> M2mEncoder<D> {
    /// Sets `device` up to encode as `settings` say and starts it streaming.
    pub fn start(mut device: D, settings: &H264Settings) -> io::Result<M2mEncoder<D>> {
        let (width, height) = (settings.width, settings.height);
        let unsupported = |message: String| io::Error::new(io::ErrorKind::Unsupported, message);
        device.set_format(Stream::Coded, PIX_FMT_H264, width, height)?;
        let raw = device.set_format(Stream::Raw, PIX_FMT_NV12, width, height)?;
        let layout = nv12_layout(width, height, &raw).ok_or_else(|| {
            unsupported(format!(
                "the encoder sets {raw:?} for NV12 of {width}x{height}"
            ))
        })?;
        let crop = device.set_crop(width, height)?;
        if crop != (width, height) {
            return Err(unsupported(format!(
                "the encoder crops {width}x{height} to {}x{}",
                crop.0, crop.1
            )));
        }
        let mut skipped = Vec::new();
        if let Err(error) = device.set_frame_rate(settings.fps) {
            skipped.push(format!("frame rate: {error}"));
        }
        let bitrate = i32::try_from(u64::from(settings.bitrate_kbps) * 1_000)
            .map_err(|_| unsupported(format!("{} kbps", settings.bitrate_kbps)))?;
        // Iris counts the frames between two key frames, one less than the interval.
        let frames_between_key_frames = i32::try_from(settings.keyframe_interval - 1)
            .map_err(|_| unsupported(format!("{} frames", settings.keyframe_interval)))?;
        let required = [
            ("bitrate", CID_BITRATE, bitrate),
            (
                "key frame interval",
                CID_GOP_SIZE,
                frames_between_key_frames,
            ),
        ];
        for (name, id, value) in required {
            if !device.has_control(id) {
                return Err(unsupported(format!("the encoder has no {name} control")));
            }
            device.set_control(id, value)?;
        }
        let optional = [
            ("constant bitrate", CID_BITRATE_MODE, BITRATE_MODE_CBR),
            ("no B frames", CID_B_FRAMES, 0),
            (
                "headers with the first frame",
                CID_HEADER_MODE,
                HEADER_MODE_JOINED_WITH_FIRST_FRAME,
            ),
        ];
        for (name, id, value) in optional {
            set_optional(&mut device, name, id, value, &mut skipped)?;
        }
        // A viewer joining mid-stream decodes from the parameter sets of the next key frame.
        let repeat_parameter_sets = [CID_PREPEND_SPSPPS_TO_IDR, CID_REPEAT_SEQ_HEADER]
            .into_iter()
            .find(|&id| device.has_control(id))
            .ok_or_else(|| {
                unsupported(
                    "the encoder has no control to repeat the parameter sets at each key frame"
                        .to_string(),
                )
            })?;
        device.set_control(repeat_parameter_sets, 1)?;
        let raw_buffers = device.request_buffers(Stream::Raw, BUFFERS)?;
        let coded_buffers = device.request_buffers(Stream::Coded, BUFFERS)?;
        for index in 0..coded_buffers {
            device.queue(Stream::Coded, index, 0, 0)?;
        }
        device.stream_on(Stream::Raw)?;
        device.stream_on(Stream::Coded)?;
        Ok(M2mEncoder {
            device,
            layout,
            free_raw: (0..raw_buffers).rev().collect(),
            pending: VecDeque::new(),
            streaming: true,
            skipped,
            timeout: ENCODE_TIMEOUT,
        })
    }

    /// A raw buffer free to fill, waiting until `deadline` for one.
    fn free_raw_buffer(&mut self, deadline: Instant) -> io::Result<u32> {
        loop {
            while let Some(done) = self.device.dequeue(Stream::Raw)? {
                self.free_raw.push(done.index);
            }
            if let Some(index) = self.free_raw.pop() {
                return Ok(index);
            }
            self.wait_until(Stream::Raw, deadline, "a raw buffer back")?;
        }
    }

    fn wait_until(
        &mut self,
        stream: Stream,
        deadline: Instant,
        waiting_for: &str,
    ) -> io::Result<()> {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("the encoder gave no {waiting_for} in {:?}", self.timeout),
            ));
        }
        self.device.wait(stream, left)
    }

    /// The frame `coded` holds, with the frames before it the encoder gave
    /// nothing for dropped, then gives its buffer back to the device. `None`
    /// for a buffer flagged as damaged or empty.
    fn take_coded(&mut self, coded: DequeuedBuffer) -> io::Result<Option<EncodedFrame>> {
        let timestamp_us = coded.timestamp_ns.div_euclid(1_000);
        let position = (self.pending.iter())
            .position(|(capture_ns, _)| capture_ns.div_euclid(1_000) == timestamp_us);
        let frame = position.and_then(|position| {
            let (capture_ns, queued) = self.pending.drain(..=position).next_back()?;
            let data = coded.data_offset..coded.bytes_used;
            (coded.flags & BUF_FLAG_ERROR == 0 && !data.is_empty()).then(|| {
                let bytes = self.device.coded_buffer(coded.index)[data].to_vec();
                // Iris leaves the key frame flag out.
                let key_frame =
                    coded.flags & BUF_FLAG_KEYFRAME != 0 || starts_with_idr_slice(&bytes);
                EncodedFrame {
                    capture_ns,
                    key_frame,
                    bytes,
                    took: queued.elapsed(),
                }
            })
        });
        self.device.queue(Stream::Coded, coded.index, 0, 0)?;
        Ok(frame)
    }
}

const NAL_TYPE_SLICE: u8 = 1;
const NAL_TYPE_IDR_SLICE: u8 = 5;

/// Whether the first slice of `stream`, H.264 in Annex B form, is an IDR
/// slice: the frame is a key frame.
fn starts_with_idr_slice(stream: &[u8]) -> bool {
    let mut rest = stream;
    while let Some(start) = rest.windows(3).position(|bytes| bytes == [0, 0, 1]) {
        let Some(&header) = rest.get(start + 3) else {
            return false;
        };
        match header & 0x1f {
            NAL_TYPE_IDR_SLICE => return true,
            NAL_TYPE_SLICE => return false,
            _ => rest = &rest[start + 4..],
        }
    }
    false
}

/// Sets control `id` to `value` when the device has it; notes in `skipped`
/// what it does, `name`, when it does not.
fn set_optional<D: M2mDevice>(
    device: &mut D,
    name: &str,
    id: u32,
    value: i32,
    skipped: &mut Vec<String>,
) -> io::Result<()> {
    if device.has_control(id) {
        device.set_control(id, value)
    } else {
        skipped.push(format!("{name}: no control"));
        Ok(())
    }
}

/// Where NV12 of `width` x `height` lies in the buffers of `format`: the
/// chroma plane after the rows of the format's height, which the device pads.
fn nv12_layout(width: u32, height: u32, format: &BufferFormat) -> Option<Nv12Layout> {
    let (stride, luma_rows) = (format.bytes_per_line as usize, format.height as usize);
    let fits = format.width >= width
        && format.height >= height
        && stride >= width as usize
        && format.size as usize >= stride * luma_rows * 3 / 2;
    fits.then_some(Nv12Layout {
        width: width as usize,
        height: height as usize,
        stride,
        luma_rows,
        size: format.size as usize,
    })
}

impl<D: M2mDevice> Encoder for M2mEncoder<D> {
    fn layout(&self) -> Nv12Layout {
        self.layout
    }

    fn encode(&mut self, nv12: &[u8], capture_ns: i64) -> io::Result<Option<EncodedFrame>> {
        let deadline = Instant::now() + self.timeout;
        let index = self.free_raw_buffer(deadline)?;
        self.device.raw_buffer(index)[..nv12.len()].copy_from_slice(nv12);
        self.device
            .queue(Stream::Raw, index, nv12.len(), capture_ns)?;
        self.pending.push_back((capture_ns, Instant::now()));
        loop {
            while let Some(coded) = self.device.dequeue(Stream::Coded)? {
                let frame = self.take_coded(coded)?;
                if let Some(frame) = frame.filter(|frame| frame.capture_ns == capture_ns) {
                    return Ok(Some(frame));
                }
            }
            if !self
                .pending
                .iter()
                .any(|&(pending, _)| pending == capture_ns)
            {
                return Ok(None);
            }
            self.wait_until(Stream::Coded, deadline, "frame")?;
        }
    }

    fn stop(&mut self) -> io::Result<()> {
        if !self.streaming {
            return Ok(());
        }
        self.streaming = false;
        let drained = self.drain();
        let raw_off = self.device.stream_off(Stream::Raw);
        let coded_off = self.device.stream_off(Stream::Coded);
        self.pending.clear();
        drained.and(raw_off).and(coded_off)
    }
}

impl<D: M2mDevice> M2mEncoder<D> {
    /// Asks the encoder to finish and dequeues its stream, dropped, up to the last buffer.
    fn drain(&mut self) -> io::Result<()> {
        self.device.stop_encoding()?;
        let deadline = Instant::now() + self.timeout;
        loop {
            match self.device.dequeue(Stream::Coded) {
                Ok(Some(coded)) if coded.flags & BUF_FLAG_LAST != 0 => return Ok(()),
                Ok(Some(coded)) => {
                    self.take_coded(coded)?;
                }
                Ok(None) => self.wait_until(Stream::Coded, deadline, "last buffer")?,
                Err(error) if error.kind() == io::ErrorKind::BrokenPipe => return Ok(()),
                Err(error) => return Err(error),
            }
        }
    }
}

impl<D: M2mDevice> Drop for M2mEncoder<D> {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

impl<D: M2mDevice> fmt::Display for M2mEncoder<D> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let layout = &self.layout;
        write!(
            formatter,
            "{}x{} NV12 in rows of {} bytes, chroma after {} rows",
            layout.width, layout.height, layout.stride, layout.luma_rows
        )?;
        if !self.skipped.is_empty() {
            write!(formatter, "; without {}", self.skipped.join(", "))?;
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    /// What the fake device was asked, in order.
    #[derive(Clone, Debug, PartialEq)]
    enum Call {
        Format(Stream, u32, u32, u32),
        Crop(u32, u32),
        FrameRate(u32),
        Control(u32, i32),
        Request(Stream, u32),
        Queue(Stream, u32, usize, i64),
        StreamOn(Stream),
        StreamOff(Stream),
        StopEncoding,
    }

    /// An encoder that makes a frame of each raw buffer queued, as Iris does:
    /// its stream the raw frame's first bytes after a 4-byte offset, a key
    /// frame every `keyframe_interval` frames, the raw buffer back as soon as
    /// it is read. A frame of `damaged` comes back flagged as damaged.
    struct FakeDevice {
        calls: Arc<Mutex<Vec<Call>>>,
        controls: Vec<u32>,
        keyframe_interval: u32,
        raw: Vec<Vec<u8>>,
        coded: Vec<Vec<u8>>,
        raw_done: VecDeque<u32>,
        coded_queued: VecDeque<u32>,
        coded_done: VecDeque<DequeuedBuffer>,
        frames: u32,
        stopped: bool,
        last_dequeued: bool,
        damaged: Option<u32>,
        /// Whether it flags key frames, which Iris does not.
        flags_key_frames: bool,
        /// Frames held back until the drain, none when the encoder is stuck.
        hold: bool,
        held: VecDeque<(u32, i64)>,
    }

    const RAW_FORMAT: BufferFormat = BufferFormat {
        width: 32,
        height: 32,
        bytes_per_line: 32,
        size: 32 * 32 * 3 / 2,
    };

    impl FakeDevice {
        fn new() -> FakeDevice {
            FakeDevice {
                calls: Arc::default(),
                controls: vec![
                    CID_BITRATE,
                    CID_GOP_SIZE,
                    CID_BITRATE_MODE,
                    CID_B_FRAMES,
                    CID_HEADER_MODE,
                    CID_PREPEND_SPSPPS_TO_IDR,
                ],
                keyframe_interval: 3,
                raw: Vec::new(),
                coded: Vec::new(),
                raw_done: VecDeque::new(),
                coded_queued: VecDeque::new(),
                coded_done: VecDeque::new(),
                frames: 0,
                stopped: false,
                last_dequeued: false,
                damaged: None,
                flags_key_frames: true,
                hold: false,
                held: VecDeque::new(),
            }
        }

        fn record(&self, call: Call) {
            self.calls.lock().unwrap().push(call);
        }

        fn calls(&self) -> Vec<Call> {
            self.calls.lock().unwrap().clone()
        }

        fn encode_into_next_coded(&mut self, index: u32, timestamp_ns: i64) {
            let coded = self
                .coded_queued
                .pop_front()
                .expect("a coded buffer queued");
            let frame = self.frames;
            self.frames += 1;
            let bytes = [&[0xee; 4][..], &self.raw[index as usize][..6]].concat();
            self.coded[coded as usize][..bytes.len()].copy_from_slice(&bytes);
            let mut flags = 0;
            if self.flags_key_frames && frame.is_multiple_of(self.keyframe_interval) {
                flags |= BUF_FLAG_KEYFRAME;
            }
            if self.damaged == Some(frame) {
                flags |= BUF_FLAG_ERROR;
            }
            self.coded_done.push_back(DequeuedBuffer {
                index: coded,
                bytes_used: bytes.len(),
                data_offset: 4,
                flags,
                timestamp_ns: timestamp_ns - timestamp_ns.rem_euclid(1_000),
            });
        }
    }

    impl M2mDevice for FakeDevice {
        fn set_format(
            &mut self,
            stream: Stream,
            pixel_format: u32,
            width: u32,
            height: u32,
        ) -> io::Result<BufferFormat> {
            self.record(Call::Format(stream, pixel_format, width, height));
            Ok(match stream {
                Stream::Raw => RAW_FORMAT,
                Stream::Coded => BufferFormat {
                    width,
                    height,
                    bytes_per_line: 0,
                    size: 4096,
                },
            })
        }

        fn set_crop(&mut self, width: u32, height: u32) -> io::Result<(u32, u32)> {
            self.record(Call::Crop(width, height));
            Ok((width, height))
        }

        fn set_frame_rate(&mut self, fps: u32) -> io::Result<()> {
            self.record(Call::FrameRate(fps));
            Err(io::Error::from_raw_os_error(libc::EINVAL))
        }

        fn has_control(&self, id: u32) -> bool {
            self.controls.contains(&id)
        }

        fn set_control(&mut self, id: u32, value: i32) -> io::Result<()> {
            self.record(Call::Control(id, value));
            Ok(())
        }

        fn request_buffers(&mut self, stream: Stream, count: u32) -> io::Result<u32> {
            self.record(Call::Request(stream, count));
            let made = count + 1;
            match stream {
                Stream::Raw => self.raw = vec![vec![0; RAW_FORMAT.size as usize]; made as usize],
                Stream::Coded => self.coded = vec![vec![0; 4096]; made as usize],
            }
            Ok(made)
        }

        fn raw_buffer(&mut self, index: u32) -> &mut [u8] {
            &mut self.raw[index as usize]
        }

        fn coded_buffer(&self, index: u32) -> &[u8] {
            &self.coded[index as usize]
        }

        fn queue(
            &mut self,
            stream: Stream,
            index: u32,
            bytes_used: usize,
            timestamp_ns: i64,
        ) -> io::Result<()> {
            self.record(Call::Queue(stream, index, bytes_used, timestamp_ns));
            match stream {
                Stream::Coded => self.coded_queued.push_back(index),
                Stream::Raw if self.hold => self.held.push_back((index, timestamp_ns)),
                Stream::Raw => {
                    self.encode_into_next_coded(index, timestamp_ns);
                    self.raw_done.push_back(index);
                }
            }
            Ok(())
        }

        fn dequeue(&mut self, stream: Stream) -> io::Result<Option<DequeuedBuffer>> {
            match stream {
                Stream::Raw => Ok(self.raw_done.pop_front().map(|index| DequeuedBuffer {
                    index,
                    bytes_used: 0,
                    data_offset: 0,
                    flags: 0,
                    timestamp_ns: 0,
                })),
                Stream::Coded if self.last_dequeued => Err(io::ErrorKind::BrokenPipe.into()),
                Stream::Coded => {
                    let done = self.coded_done.pop_front();
                    if done.is_some_and(|done| done.flags & BUF_FLAG_LAST != 0) {
                        self.last_dequeued = true;
                    }
                    Ok(done)
                }
            }
        }

        fn wait(&mut self, _stream: Stream, _timeout: Duration) -> io::Result<()> {
            Ok(())
        }

        fn stream_on(&mut self, stream: Stream) -> io::Result<()> {
            self.record(Call::StreamOn(stream));
            Ok(())
        }

        fn stream_off(&mut self, stream: Stream) -> io::Result<()> {
            self.record(Call::StreamOff(stream));
            Ok(())
        }

        fn stop_encoding(&mut self) -> io::Result<()> {
            self.record(Call::StopEncoding);
            self.stopped = true;
            while let Some((index, timestamp_ns)) = self.held.pop_front() {
                self.encode_into_next_coded(index, timestamp_ns);
            }
            let last = self
                .coded_queued
                .pop_front()
                .expect("a coded buffer queued");
            self.coded_done.push_back(DequeuedBuffer {
                index: last,
                bytes_used: 0,
                data_offset: 0,
                flags: BUF_FLAG_LAST,
                timestamp_ns: 0,
            });
            Ok(())
        }
    }

    const SETTINGS: H264Settings = H264Settings {
        width: 30,
        height: 20,
        bitrate_kbps: 4_000,
        keyframe_interval: 3,
        fps: 30,
    };

    fn raw_frame(first: u8) -> Vec<u8> {
        (0..RAW_FORMAT.size as usize)
            .map(|byte| first.wrapping_add(byte as u8))
            .collect()
    }

    #[test]
    fn the_encoder_is_set_up_and_streams_before_its_first_frame() {
        let encoder = M2mEncoder::start(FakeDevice::new(), &SETTINGS).unwrap();
        let (width, height) = (30, 20);
        let mut expected = vec![
            Call::Format(Stream::Coded, PIX_FMT_H264, width, height),
            Call::Format(Stream::Raw, PIX_FMT_NV12, width, height),
            Call::Crop(width, height),
            Call::FrameRate(30),
            Call::Control(CID_BITRATE, 4_000_000),
            Call::Control(CID_GOP_SIZE, 2),
            Call::Control(CID_BITRATE_MODE, BITRATE_MODE_CBR),
            Call::Control(CID_B_FRAMES, 0),
            Call::Control(CID_HEADER_MODE, HEADER_MODE_JOINED_WITH_FIRST_FRAME),
            Call::Control(CID_PREPEND_SPSPPS_TO_IDR, 1),
            Call::Request(Stream::Raw, BUFFERS),
            Call::Request(Stream::Coded, BUFFERS),
        ];
        expected.extend((0..BUFFERS + 1).map(|index| Call::Queue(Stream::Coded, index, 0, 0)));
        expected.extend([Call::StreamOn(Stream::Raw), Call::StreamOn(Stream::Coded)]);
        assert_eq!(encoder.device.calls(), expected);
        assert_eq!(
            encoder.layout(),
            Nv12Layout {
                width: 30,
                height: 20,
                stride: 32,
                luma_rows: 32,
                size: 1_536,
            }
        );
        assert_eq!(
            encoder.to_string(),
            "30x20 NV12 in rows of 32 bytes, chroma after 32 rows; \
             without frame rate: Invalid argument (os error 22)"
        );
    }

    #[test]
    fn an_encoder_without_a_bitrate_control_or_the_crop_asked_is_refused() {
        let mut device = FakeDevice::new();
        device.controls.retain(|&id| id != CID_BITRATE);
        let refused = M2mEncoder::start(device, &SETTINGS).err().unwrap();
        assert_eq!(refused.kind(), io::ErrorKind::Unsupported);
        assert_eq!(refused.to_string(), "the encoder has no bitrate control");

        let too_large = H264Settings {
            width: 40,
            ..SETTINGS
        };
        let refused = M2mEncoder::start(FakeDevice::new(), &too_large)
            .err()
            .unwrap();
        assert!(
            refused
                .to_string()
                .starts_with("the encoder sets BufferFormat"),
            "{refused}"
        );
    }

    #[test]
    fn the_parameter_sets_repeat_through_the_other_control_when_the_first_is_missing() {
        let mut device = FakeDevice::new();
        device.controls = vec![CID_BITRATE, CID_GOP_SIZE, CID_REPEAT_SEQ_HEADER];
        let encoder = M2mEncoder::start(device, &SETTINGS).unwrap();
        assert!(encoder
            .device
            .calls()
            .contains(&Call::Control(CID_REPEAT_SEQ_HEADER, 1)));
        assert!(
            encoder.to_string().ends_with(
                "constant bitrate: no control, no B frames: no control, \
                 headers with the first frame: no control"
            ),
            "{encoder}"
        );
    }

    #[test]
    fn an_encoder_that_cannot_repeat_the_parameter_sets_at_each_key_frame_is_refused() {
        let mut device = FakeDevice::new();
        device.controls = vec![CID_BITRATE, CID_GOP_SIZE];
        let refused = M2mEncoder::start(device, &SETTINGS).err().unwrap();
        assert_eq!(refused.kind(), io::ErrorKind::Unsupported);
        assert_eq!(
            refused.to_string(),
            "the encoder has no control to repeat the parameter sets at each key frame"
        );
    }

    #[test]
    fn each_frame_comes_back_encoded_in_order_with_its_key_frame_flag() {
        let mut encoder = M2mEncoder::start(FakeDevice::new(), &SETTINGS).unwrap();
        let start = encoder.device.calls().len();
        let mut frames = Vec::new();
        for frame in 0..8u8 {
            let capture_ns = 1_000_123 * (i64::from(frame) + 1);
            let encoded = encoder.encode(&raw_frame(frame), capture_ns).unwrap();
            frames.push(encoded.unwrap());
        }
        for (frame, encoded) in frames.iter().enumerate() {
            assert_eq!(encoded.capture_ns, 1_000_123 * (frame as i64 + 1));
            assert_eq!(encoded.key_frame, frame % 3 == 0, "frame {frame}");
            let first = frame as u8;
            assert_eq!(encoded.bytes, (first..first + 6).collect::<Vec<_>>());
        }
        // Each frame in a raw buffer the device gave back, then its coded buffer back.
        let calls = encoder.device.calls();
        let queued = &calls[start..];
        assert_eq!(queued.len(), 16);
        for (frame, pair) in queued.chunks(2).enumerate() {
            let capture_ns = 1_000_123 * (frame as i64 + 1);
            assert!(
                matches!(pair[0], Call::Queue(Stream::Raw, _, 1_536, ns) if ns == capture_ns),
                "{pair:?}"
            );
            assert!(
                matches!(pair[1], Call::Queue(Stream::Coded, _, 0, 0)),
                "{pair:?}"
            );
        }
    }

    #[test]
    fn a_frame_whose_first_slice_is_an_idr_slice_is_a_key_frame_without_the_flag() {
        let nal = |header: u8| [&[0, 0, 0, 1, header][..], &[0x88, 0x84]].concat();
        let (sps, pps, sei, idr, slice) = (nal(0x67), nal(0x68), nal(0x06), nal(0x65), nal(0x41));
        assert!(starts_with_idr_slice(
            &[sps.clone(), pps.clone(), idr.clone()].concat()
        ));
        assert!(starts_with_idr_slice(&[sei.clone(), idr.clone()].concat()));
        assert!(starts_with_idr_slice(
            &[&[0, 0, 1, 0x65][..], &[1]].concat()
        ));
        assert!(!starts_with_idr_slice(&slice));
        assert!(!starts_with_idr_slice(&[slice, idr].concat()));
        assert!(!starts_with_idr_slice(&[sps, pps].concat()));
        assert!(!starts_with_idr_slice(&[]));

        let mut device = FakeDevice::new();
        device.flags_key_frames = false;
        let mut encoder = M2mEncoder::start(device, &SETTINGS).unwrap();
        let mut idr_frame = raw_frame(0);
        idr_frame[..5].copy_from_slice(&[0, 0, 0, 1, 0x65]);
        let mut other_frame = raw_frame(0);
        other_frame[..5].copy_from_slice(&[0, 0, 0, 1, 0x41]);
        let key = |encoder: &mut M2mEncoder<FakeDevice>, frame: &[u8], capture_ns| {
            let encoded = encoder.encode(frame, capture_ns).unwrap().unwrap();
            encoded.key_frame
        };
        assert!(key(&mut encoder, &idr_frame, 1_000));
        assert!(!key(&mut encoder, &other_frame, 2_000));
    }

    #[test]
    fn a_frame_flagged_as_damaged_comes_back_as_none() {
        let mut device = FakeDevice::new();
        device.damaged = Some(1);
        let mut encoder = M2mEncoder::start(device, &SETTINGS).unwrap();
        let encoded: Vec<Option<i64>> = (1..=3)
            .map(|frame| {
                let encoded = encoder.encode(&raw_frame(0), frame * 1_000).unwrap();
                encoded.map(|frame| frame.capture_ns)
            })
            .collect();
        assert_eq!(encoded, [Some(1_000), None, Some(3_000)]);
    }

    #[test]
    fn stopping_drains_the_encoder_to_its_last_buffer_then_stops_both_streams() {
        let mut encoder = M2mEncoder::start(FakeDevice::new(), &SETTINGS).unwrap();
        encoder.encode(&raw_frame(0), 1_000).unwrap();
        encoder.device.hold = true;
        encoder.timeout = Duration::from_millis(10);
        let start = encoder.device.calls().len();

        let stuck = encoder.encode(&raw_frame(1), 2_000).unwrap_err();
        assert_eq!(stuck.kind(), io::ErrorKind::TimedOut);
        assert_eq!(stuck.to_string(), "the encoder gave no frame in 10ms");
        encoder.stop().unwrap();
        encoder.stop().unwrap();

        let calls = encoder.device.calls();
        assert_eq!(
            calls[start + 1..],
            [
                Call::StopEncoding,
                Call::Queue(Stream::Coded, 1, 0, 0),
                Call::StreamOff(Stream::Raw),
                Call::StreamOff(Stream::Coded),
            ]
        );
        assert!(encoder.device.last_dequeued);
    }

    #[test]
    fn dropping_a_streaming_encoder_stops_it() {
        let device = FakeDevice::new();
        let log = Arc::clone(&device.calls);
        drop(M2mEncoder::start(device, &SETTINGS).unwrap());
        let calls = log.lock().unwrap();
        assert_eq!(
            calls[calls.len() - 3..],
            [
                Call::StopEncoding,
                Call::StreamOff(Stream::Raw),
                Call::StreamOff(Stream::Coded),
            ]
        );
    }
}
