//! A single colour camera's frame loop: captures its raw RGGB frames, makes
//! each output's image of them (`plan`), steers the exposure and the white
//! balance from what they measure, and writes one OUTPUT_FRAME, OUTPUT_JPEG
//! or OUTPUT_H264 record per sent output per frame on stdout, in the
//! outputs' order.

use std::fs::File;
use std::io;
use std::os::fd::{AsFd, AsRawFd, RawFd};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use framing::{log_record, metadata_record, output_h264_header, LogLevel, Writer};

use crate::arguments::{Format, OutputSpec, SingleArguments};
use crate::bayer::{RawFrame, Tone};
use crate::cpus;
use crate::encoder::{Encoder, H264Settings, M2mEncoder};
use crate::h264::{self, EncodedVideo};
use crate::jpeg::{self, Encoded};
use crate::plan::{Plan, Sent};
use crate::processor::Development;
use crate::sensor::{self, SensorModel};
use crate::settings::ColourSettings;
use crate::v4l2;
use crate::white_balance::{self, Gains};
use crate::{
    auto_exposure, auto_exposure_from, capped_now, input, open_camera, pollfd, resume_point,
    EXPOSURE_EVERY_FRAMES, EXPOSURE_GAIN_PRESENT, EXPOSURE_MARGIN_LINES, STATISTICS_EVERY_S,
};

/// Captures the camera `arguments` names at its full sensor size until the
/// host closes stdin, writing each frame as each of `arguments.outputs`.
pub fn run(
    arguments: &SingleArguments,
    writer: &Writer,
    log: &dyn Fn(LogLevel, &str),
) -> io::Result<()> {
    let (sensor_width, sensor_height) = (arguments.sensor_width, arguments.sensor_height);
    // Before any thread starts, so that every thread inherits the CPUs.
    match cpus::avoid_slowest() {
        Ok(Some(cpus)) => log(LogLevel::Info, &format!("running on CPUs {cpus:?}")),
        Ok(None) => {}
        Err(error) => log(
            LogLevel::Warning,
            &format!("running on every CPU, the slowest kept: {error}"),
        ),
    }
    let model = SensorModel::for_sensor(&arguments.camera.sensor);
    let encoders = start_encoders(arguments, log)?;
    let camera = open_camera(&arguments.camera, sensor_width, sensor_height)?;
    let sensor = &camera.sensor;

    let hblank = sensor.control(v4l2::CID_HBLANK)?;
    let pixel_rate = sensor.control64(v4l2::CID_PIXEL_RATE)?;
    let line_ns = sensor::line_ns(sensor_width, hblank as u32, pixel_rate as u64);
    let (vblank_min, vblank_max) = sensor.control_range(v4l2::CID_VBLANK)?;
    let frame_lines = (1e9 / f64::from(arguments.fps) / line_ns).round() as i32;
    let vblank = (frame_lines - sensor_height as i32).clamp(vblank_min, vblank_max);
    let period_ns = (f64::from(sensor_height as i32 + vblank) * line_ns).round() as i64;
    let gain_range = sensor.control_range(v4l2::CID_ANALOGUE_GAIN)?;
    let frame_us = period_ns as f64 / 1_000.0;
    let max_exposure_lines = sensor_height as i32 + vblank - EXPOSURE_MARGIN_LINES;
    let set_exposure = |exposure_us: f64, gain: f64| -> io::Result<(f64, f64)> {
        let lines = ((exposure_us * 1_000.0 / line_ns).round() as i32).clamp(1, max_exposure_lines);
        let code = model.gain_code(gain, gain_range.0, gain_range.1);
        sensor.set_control(v4l2::CID_EXPOSURE, lines)?;
        sensor.set_control(v4l2::CID_ANALOGUE_GAIN, code)?;
        Ok((f64::from(lines) * line_ns / 1_000.0, model.gain(code)))
    };
    sensor.set_control(v4l2::CID_VBLANK, vblank)?;

    let settings = arguments.settings.clone();
    writer.write_record(&exposure_record(
        set_exposure(
            f64::from(settings.capture.exposure_us),
            settings.capture.analogue_gain,
        )?,
        0,
    ))?;
    log(
        LogLevel::Info,
        &format!(
            "{sensor_width}x{sensor_height} {:?} to {:?}, line {line_ns:.1} ns, \
             vblank {vblank}, period {period_ns} ns, {settings:?}",
            camera.capture.layout, arguments.outputs
        ),
    );
    let frames = CameraFrames {
        capture: &camera.capture,
        width: sensor_width as usize,
        height: sensor_height as usize,
    };
    let setup = Setup {
        outputs: arguments.outputs.clone(),
        model,
        frame_us,
        settings,
        statistics_every: Duration::from_secs(STATISTICS_EVERY_S),
        encoders,
    };
    let mut input = input::unbuffered(io::stdin().as_fd())?;
    capture(setup, &frames, &set_exposure, &mut input, writer)
}

/// The sysfs name of the video encoder node: Qualcomm's Iris, on the VENTUNO Q.
const VIDEO_ENCODER: &str = "qcom-iris-encoder";

/// An encoder for each output of `arguments` sent as H.264, in their order,
/// started at the camera's frame rate.
fn start_encoders(
    arguments: &SingleArguments,
    log: &dyn Fn(LogLevel, &str),
) -> io::Result<Vec<Box<dyn Encoder>>> {
    let mut encoders: Vec<Box<dyn Encoder>> = Vec::new();
    for (index, spec) in arguments.outputs.iter().enumerate() {
        let Format::H264 {
            bitrate_kbps,
            keyframe_interval,
        } = spec.format
        else {
            continue;
        };
        let settings = H264Settings {
            width: spec.width,
            height: spec.height,
            bitrate_kbps,
            keyframe_interval,
            fps: arguments.fps,
        };
        let encoder = v4l2::M2mNode::open_named(VIDEO_ENCODER)
            .and_then(|node| M2mEncoder::start(node, &settings))
            .map_err(|error| {
                let message = format!("output {index}: H.264 on {VIDEO_ENCODER}: {error}");
                io::Error::new(error.kind(), message)
            })?;
        log(
            LogLevel::Info,
            &format!("output {index}: H.264 {settings:?} from {encoder}"),
        );
        encoders.push(Box::new(encoder));
    }
    Ok(encoders)
}

/// The record telling the host the exposure and gain just applied, stamped
/// with a frame start.
fn exposure_record((exposure_us, gain): (f64, f64), capture_ns: i64) -> Vec<u8> {
    let mut values = [0.0; framing::METADATA_FIELDS];
    values[0] = exposure_us;
    values[1] = gain;
    metadata_record(capture_ns, EXPOSURE_GAIN_PRESENT, &values)
}

/// Where the frame loop takes its frames from.
trait Frames {
    /// The descriptor `poll` reports a frame ready on.
    fn descriptor(&self) -> RawFd;

    /// Hands the next frame ready to `take`, with its start, or `None` for
    /// one incomplete, then gives its buffer back to the driver; `None`
    /// when no frame is ready.
    fn next<T>(&self, take: impl FnOnce(Option<(RawFrame, i64)>) -> T) -> io::Result<Option<T>>;
}

/// The frames of a capture node, `width` x `height` samples each.
struct CameraFrames<'a> {
    capture: &'a v4l2::Capture,
    width: usize,
    height: usize,
}

impl Frames for CameraFrames<'_> {
    fn descriptor(&self) -> RawFd {
        self.capture.node.fd
    }

    fn next<T>(&self, take: impl FnOnce(Option<(RawFrame, i64)>) -> T) -> io::Result<Option<T>> {
        let Some(frame) = self.capture.dequeue()? else {
            return Ok(None);
        };
        let whole = self.capture.complete(&frame).then(|| {
            let raw = RawFrame {
                raw: self.capture.pixels(&frame),
                width: self.width,
                height: self.height,
                row_stride: self.capture.row_stride,
                layout: self.capture.layout,
            };
            (raw, frame.start_ns)
        });
        let taken = take(whole);
        self.capture.queue(frame.index)?;
        Ok(Some(taken))
    }
}

/// Where the frame loop writes its records.
trait Records: Sync {
    /// Writes one record of `parts`.
    fn write(&self, parts: &[&[u8]]) -> io::Result<()>;
}

impl Records for Writer {
    fn write(&self, parts: &[&[u8]]) -> io::Result<()> {
        self.write_record_parts(parts)
    }
}

/// What the frame loop starts from.
struct Setup {
    outputs: Vec<OutputSpec>,
    model: SensorModel,
    /// A frame's period.
    frame_us: f64,
    settings: ColourSettings,
    /// How often the statistics are logged.
    statistics_every: Duration,
    /// The encoder of each output sent as H.264, in their order.
    encoders: Vec<Box<dyn Encoder>>,
}

/// Converts the frames of `frames` as `setup` says and writes them to
/// `records`, each on a writer thread while the next one converts, its
/// JPEG outputs encoded on an encoder thread and its H.264 outputs on
/// another while the writer writes its other outputs, steering the sensor's exposure through `set_exposure`
/// and applying the settings `input` sends, until `input` closes. The
/// records keep the order they are sent in.
fn capture(
    mut setup: Setup,
    frames: &impl Frames,
    set_exposure: &dyn Fn(f64, f64) -> io::Result<(f64, f64)>,
    input: &mut File,
    records: &impl Records,
) -> io::Result<()> {
    let encoders = std::mem::take(&mut setup.encoders);
    let layouts: Vec<_> = encoders.iter().map(|encoder| encoder.layout()).collect();
    let plan = Plan::new(&setup.outputs, setup.model, &layouts);
    let jpeg_outputs = plan.jpeg_outputs();
    let mut video_outputs: Vec<(usize, Box<dyn Encoder>)> =
        plan.h264_outputs().into_iter().zip(encoders).collect();
    std::thread::scope(|scope| {
        let (sender, queued) = mpsc::channel();
        let (written, images) = mpsc::channel();
        let (to_encode, frames_to_encode) = mpsc::channel();
        let (encoded_sender, encoded) = mpsc::channel();
        let (to_video, frames_to_video) = mpsc::channel();
        let (video_sender, video) = mpsc::channel();
        let jpeg_encoder = (!jpeg_outputs.is_empty()).then(|| {
            scope
                .spawn(move || jpeg::encode_frames(&jpeg_outputs, frames_to_encode, encoded_sender))
        });
        let video_encoder = (!video_outputs.is_empty()).then(|| {
            scope.spawn(move || {
                h264::encode_frames(&mut video_outputs, frames_to_video, video_sender)
            })
        });
        let encodings = Encodings {
            jpegs: jpeg_encoder.is_some().then_some(encoded),
            video: video_encoder.is_some().then_some(video),
        };
        let writer = scope.spawn(move || write_records(records, encodings, queued, written));
        let queue = Queue {
            records: sender,
            to_encode: jpeg_encoder.is_some().then_some(to_encode),
            to_video: video_encoder.is_some().then_some(to_video),
            images,
        };
        let converted = convert_frames(setup, plan, frames, set_exposure, input, &queue);
        drop(queue);
        let joined = |thread: std::thread::ScopedJoinHandle<io::Result<()>>| {
            thread
                .join()
                .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
        };
        let written = joined(writer);
        let encoded = jpeg_encoder.map_or(Ok(()), joined);
        let video = video_encoder.map_or(Ok(()), joined);
        // After a failed encode or write the others' errors only say that thread stopped.
        encoded.and(video).and(written).and(converted)
    })
}

/// A frame's images, one per output, shared by the threads that read them.
type FrameImages = Arc<Vec<Vec<u8>>>;

/// A record for the writer thread: a frame's images, one per output, with
/// what is written of each output sent and that output's index, or another
/// record whole.
enum Record {
    Frame(Vec<(usize, Sent)>, FrameImages),
    Other(Vec<u8>),
}

/// A frame's images back from the writer thread, what writing them took,
/// what encoding its JPEGs took when it has some, and its H.264 frames.
struct Written {
    images: Vec<Vec<u8>>,
    write: Duration,
    encode: Option<Duration>,
    video: VideoWritten,
}

/// H.264 frames written: how many, what encoding them took, and their bytes.
#[derive(Default)]
struct VideoWritten {
    frames: u64,
    encode: Duration,
    bytes: u64,
}

/// What each frame's encoder threads give, from those there are.
struct Encodings {
    jpegs: Option<mpsc::Receiver<Encoded>>,
    video: Option<mpsc::Receiver<EncodedVideo>>,
}

/// Writes each record of `queued` to `records`, a frame's sent outputs one
/// record each, its JPEGs and H.264 frames from `encodings`, then hands its
/// images to `written`.
fn write_records(
    records: &impl Records,
    encodings: Encodings,
    queued: mpsc::Receiver<Record>,
    written: mpsc::Sender<Written>,
) -> io::Result<()> {
    for record in queued {
        match record {
            Record::Frame(sent, images) => {
                let (mut jpegs, mut video) = (None, None);
                let mut write = Duration::ZERO;
                let mut write_timed = |parts: &[&[u8]]| -> io::Result<()> {
                    let writing = Instant::now();
                    records.write(parts)?;
                    write += writing.elapsed();
                    Ok(())
                };
                for &(index, ref sent) in &sent {
                    match *sent {
                        Sent::Image(ref header) => write_timed(&[header, &images[index]])?,
                        Sent::Jpeg { ref header, slot } => {
                            let encoded = received(&mut jpegs, &encodings.jpegs)?;
                            write_timed(&[header, &encoded.jpegs[slot]])?
                        }
                        Sent::H264 {
                            slot,
                            width,
                            height,
                        } => {
                            let encoded = received(&mut video, &encodings.video)?;
                            if let Some(frame) = &encoded.frames[slot] {
                                let header = output_h264_header(
                                    index as u8,
                                    width,
                                    height,
                                    frame.capture_ns,
                                    frame.key_frame,
                                );
                                write_timed(&[&header, &frame.bytes])?;
                            }
                        }
                    }
                }
                // The encoders hold the images until the frame's encodes are done.
                if encodings.jpegs.is_some() {
                    received(&mut jpegs, &encodings.jpegs)?;
                }
                if encodings.video.is_some() {
                    received(&mut video, &encodings.video)?;
                }
                let encode = jpegs.map(|encoded| {
                    drop(encoded.images);
                    encoded.took
                });
                let video = video.map_or_else(VideoWritten::default, |encoded| {
                    drop(encoded.images);
                    let frames = encoded.frames.iter().flatten();
                    VideoWritten {
                        frames: frames.clone().count() as u64,
                        encode: frames.clone().map(|frame| frame.took).sum(),
                        bytes: frames.map(|frame| frame.bytes.len() as u64).sum(),
                    }
                });
                let images = Arc::into_inner(images).expect("no other thread holds the images");
                let _ = written.send(Written {
                    images,
                    write,
                    encode,
                    video,
                });
            }
            Record::Other(record) => records.write(&[&record])?,
        }
    }
    Ok(())
}

/// The frame's encodes in `slot`, received from `encoded` unless they already were.
fn received<'a, T>(
    slot: &'a mut Option<T>,
    encoded: &Option<mpsc::Receiver<T>>,
) -> io::Result<&'a T> {
    if slot.is_none() {
        let encoded = encoded.as_ref().expect("an encoder thread");
        *slot = Some(encoded.recv().map_err(|_| encoder_stopped())?);
    }
    Ok(slot.as_ref().expect("the frame's encodes"))
}

/// The records on their way to the writer thread, the frames on their way
/// to the encoder thread when there is one, and the images the writer has
/// written on their way back.
struct Queue {
    records: mpsc::Sender<Record>,
    to_encode: Option<mpsc::Sender<FrameImages>>,
    /// The frames on their way to the video encoder thread, with their start.
    to_video: Option<mpsc::Sender<(FrameImages, i64)>>,
    images: mpsc::Receiver<Written>,
}

impl Queue {
    fn send(&self, record: Record) -> io::Result<()> {
        self.records.send(record).map_err(|_| writer_stopped())
    }

    /// Sends the outputs of the frame started at `start_ns` to the writer,
    /// and its images to the encoders.
    fn send_frame(
        &self,
        sent: Vec<(usize, Sent)>,
        images: FrameImages,
        start_ns: i64,
    ) -> io::Result<()> {
        if let Some(to_encode) = &self.to_encode {
            (to_encode.send(Arc::clone(&images))).map_err(|_| encoder_stopped())?;
        }
        if let Some(to_video) = &self.to_video {
            let frame = (Arc::clone(&images), start_ns);
            to_video.send(frame).map_err(|_| encoder_stopped())?;
        }
        self.send(Record::Frame(sent, images))
    }

    /// The next frame's images written, waiting for their writes to end.
    fn written(&self) -> io::Result<Written> {
        self.images.recv().map_err(|_| writer_stopped())
    }
}

fn writer_stopped() -> io::Error {
    io::Error::other("the writer thread stopped")
}

fn encoder_stopped() -> io::Error {
    io::Error::other("the encoder thread stopped")
}

/// What the frame loop counts and times between two statistics lines.
#[derive(Default)]
struct Statistics {
    /// Frames converted, and frames dropped as incomplete.
    frames: u64,
    incomplete: u64,
    conversion: Duration,
    scaling: Duration,
    /// Frames written, and the time their writes took.
    writes: u64,
    write: Duration,
    jpegs_encoded: u64,
    encode: Duration,
    /// The time converting frames to NV12 for the H.264 outputs took.
    nv12_conversion: Duration,
    video: VideoWritten,
}

impl Statistics {
    /// The line logged after `period`, with the white balance `gains` in force and
    /// the colour temperature a tuned sensor reads from them.
    fn line(&self, period: Duration, gains: Gains, kelvin: Option<f64>) -> String {
        let micros_each =
            |total: Duration, count: u64| total.as_nanos() / 1_000 / u128::from(count.max(1));
        format!(
            "last {} s: frames {}, incomplete {}, {} us per conversion, \
             {} us per scaling, {} us per write, {} us per JPEG encode, \
             {} us per NV12 conversion, {} us per H.264 encode, \
             {} bytes per s of H.264, white balance {gains:?}{}",
            period.as_secs(),
            self.frames,
            self.incomplete,
            micros_each(self.conversion, self.frames),
            micros_each(self.scaling, self.frames),
            micros_each(self.write, self.writes),
            micros_each(self.encode, self.jpegs_encoded),
            micros_each(self.nv12_conversion, self.frames),
            micros_each(self.video.encode, self.video.frames),
            (self.video.bytes as f64 / period.as_secs_f64().max(1.0)).round(),
            kelvin
                .map(|kelvin| format!(", {kelvin:.0} K"))
                .unwrap_or_default()
        )
    }
}

/// `capture`'s loop, sending its records to `queue`.
fn convert_frames(
    setup: Setup,
    mut plan: Plan,
    frames: &impl Frames,
    set_exposure: &dyn Fn(f64, f64) -> io::Result<(f64, f64)>,
    input: &mut File,
    queue: &Queue,
) -> io::Result<()> {
    let Setup {
        model,
        frame_us,
        mut settings,
        statistics_every,
        ..
    } = setup;
    let log = |level, message: &str| {
        let _ = queue.send(Record::Other(log_record(level, message)));
    };
    let tone_for = |settings: &ColourSettings| {
        Tone::with_sample_bits(
            settings.capture.black_level,
            settings.capture.gamma,
            model.sample_bits(),
        )
    };
    let tuning = model.tuning();
    let default_threads = plan.default_threads();
    let jpegs_per_frame = plan.jpeg_count() as u64;
    let encodes_video = !plan.h264_outputs().is_empty();
    // Two sets of images alternate: one converts while the writer writes the other.
    let (mut images, mut spare) = (
        vec![Vec::new(); plan.output_count()],
        Some(vec![Vec::new(); plan.output_count()]),
    );
    let mut tone = tone_for(&settings);
    let mut gains = settings.gains();
    let mut auto_exposure = auto_exposure(&settings.capture, frame_us);
    let mut last_ns = None;

    let mut converted = 0u32;
    let mut statistics = Statistics::default();
    let mut statistics_since = Instant::now();
    let mut poll_descriptors = [pollfd(frames.descriptor()), pollfd(input.as_raw_fd())];
    loop {
        // SAFETY: `poll_descriptors` is a valid array of two pollfds.
        if unsafe { libc::poll(poll_descriptors.as_mut_ptr(), 2, 1_000) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(error);
        }
        if poll_descriptors[1].revents != 0 {
            match framing::read_record(input, input::MAX_SETTING_BYTES)? {
                None => return Ok(()),
                Some(record) => match settings.apply(&record) {
                    Ok(()) => {
                        tone = tone_for(&settings);
                        if !settings.awb {
                            gains = settings.gains();
                        }
                        let running = (auto_exposure.exposure_us, auto_exposure.gain);
                        let resume_from = resume_point(&settings.capture, running, || {
                            let applied = set_exposure(
                                f64::from(settings.capture.exposure_us),
                                settings.capture.analogue_gain,
                            )?;
                            let record = exposure_record(applied, last_ns.unwrap_or(0));
                            queue.send(Record::Other(record))?;
                            Ok(applied)
                        })?;
                        auto_exposure =
                            auto_exposure_from(&settings.capture, frame_us, resume_from);
                        if let Some((exposure_us, gain)) =
                            capped_now(&settings.capture, &mut auto_exposure)
                        {
                            let applied = set_exposure(exposure_us, gain)?;
                            let record = exposure_record(applied, last_ns.unwrap_or(0));
                            queue.send(Record::Other(record))?;
                        }
                        log(LogLevel::Info, &format!("settings: {settings:?}"));
                    }
                    Err(message) => log(LogLevel::Warning, &message),
                },
            }
        }
        if statistics_since.elapsed() >= statistics_every {
            let kelvin = tuning.map(|tuning| tuning.colour_temperature(gains));
            let line = statistics.line(statistics_every, gains, kelvin);
            log(LogLevel::Info, &line);
            statistics = Statistics::default();
            statistics_since = Instant::now();
        }
        // One frame a round: the settings and statistics are served between frames.
        if let Some(taken) = frames.next(|whole| {
            let (raw, start_ns) = whole?;
            let converting = Instant::now();
            converted += 1;
            let measure_exposure =
                settings.capture.auto_exposure && converted.is_multiple_of(EXPOSURE_EVERY_FRAMES);
            let threads = settings.threads.unwrap_or(default_threads);
            let development = Development {
                settings: &settings,
                gains,
                tone: &tone,
                channel_means: settings.awb,
                green_mean: measure_exposure,
                threads,
            };
            let measures = plan.develop(&raw, &development, &mut images);
            if let Some(means) = measures.channel_means {
                gains = white_balance::grey_world(means, gains);
            }
            statistics.conversion += converting.elapsed();
            Some((start_ns, measures.green_mean))
        })? {
            let Some((start_ns, green_mean)) = taken else {
                statistics.incomplete += 1;
                continue;
            };
            statistics.frames += 1;
            last_ns = Some(start_ns);
            if let Some(mean) = green_mean {
                if let Some((exposure_us, gain)) = auto_exposure.observe(mean) {
                    let applied = set_exposure(exposure_us, gain)?;
                    queue.send(Record::Other(exposure_record(applied, start_ns)))?;
                }
            }
            if plan.scales() {
                let scaling = Instant::now();
                let threads = settings.threads.unwrap_or(default_threads);
                plan.scale(threads, &mut images);
                statistics.scaling += scaling.elapsed();
            }
            if encodes_video {
                let converting = Instant::now();
                let threads = settings.threads.unwrap_or(default_threads);
                plan.convert_to_nv12(threads, &mut images);
                statistics.nv12_conversion += converting.elapsed();
            }
            let free = match spare.take() {
                Some(images) => images,
                None => {
                    let written = queue.written()?;
                    statistics.writes += 1;
                    statistics.write += written.write;
                    if let Some(took) = written.encode {
                        statistics.jpegs_encoded += jpegs_per_frame;
                        statistics.encode += took;
                    }
                    statistics.video.frames += written.video.frames;
                    statistics.video.encode += written.video.encode;
                    statistics.video.bytes += written.video.bytes;
                    written.images
                }
            };
            let sent = plan.sent(start_ns);
            let frame_images = Arc::new(std::mem::replace(&mut images, free));
            queue.send_frame(sent, frame_images, start_ns)?;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::{Cell, RefCell};
    use std::io::Write;
    use std::os::fd::FromRawFd;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{mpsc, Mutex};

    use super::*;
    use crate::arguments::{Format, Output, Source};
    use crate::bands::{Conversion, Images};
    use crate::bayer::tests::padded_packed12;
    use crate::bayer::Layout;
    use crate::encoder::EncodedFrame;
    use crate::nv12::{self, Nv12Layout};
    use crate::processor::tests::{develop_along, samples, Path};
    use crate::processor::MEASURED_ROW_STEP;
    use crate::scale;

    // A pipe's reading and writing ends.
    fn pipe() -> (File, File) {
        let mut ends = [0; 2];
        // SAFETY: `ends` has room for the two descriptors.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both descriptors were just created and nothing else owns them.
        unsafe { (File::from_raw_fd(ends[0]), File::from_raw_fd(ends[1])) }
    }

    const WIDTH: usize = 24;
    const HEIGHT: usize = 46;
    const STRIDE: usize = WIDTH * 3 / 2 + 6;

    // Frames in order, `None` for an incomplete one, each starting a
    // millisecond after the one before; the host's end of the settings
    // pipe sends `settings` as the frame of their index is taken, and
    // closes once the frames run out. `on_take` hears each frame's index
    // as it is taken.
    struct TestFrames {
        frames: Vec<Option<Vec<u8>>>,
        taken: Cell<usize>,
        // Readable for as long as the test runs: a byte nobody reads.
        ready: (File, File),
        host: RefCell<Option<File>>,
        settings: Vec<(usize, &'static str)>,
        on_take: Option<mpsc::Sender<usize>>,
    }

    impl TestFrames {
        // The frames and the input the loop reads the settings from.
        fn new(frames: Vec<Option<Vec<u8>>>, settings: Vec<(usize, &'static str)>) -> (Self, File) {
            let ready = pipe();
            (&ready.1).write_all(&[1]).unwrap();
            let (input, host) = pipe();
            let frames = TestFrames {
                frames,
                taken: Cell::new(0),
                ready,
                host: RefCell::new(Some(host)),
                settings,
                on_take: None,
            };
            (frames, input)
        }
    }

    impl Frames for TestFrames {
        fn descriptor(&self) -> RawFd {
            self.ready.0.as_raw_fd()
        }

        fn next<T>(
            &self,
            take: impl FnOnce(Option<(RawFrame, i64)>) -> T,
        ) -> io::Result<Option<T>> {
            let index = self.taken.get();
            let Some(frame) = self.frames.get(index) else {
                self.host.borrow_mut().take();
                return Ok(None);
            };
            self.taken.set(index + 1);
            if let Some(on_take) = &self.on_take {
                let _ = on_take.send(index);
            }
            for (_, setting) in self.settings.iter().filter(|(at, _)| *at == index) {
                let record = [
                    &(setting.len() as u32).to_be_bytes()[..],
                    setting.as_bytes(),
                ];
                let mut host = self.host.borrow_mut();
                host.as_mut().unwrap().write_all(&record.concat())?;
            }
            let whole = frame.as_ref().map(|raw| {
                let frame = RawFrame {
                    raw,
                    width: WIDTH,
                    height: HEIGHT,
                    row_stride: STRIDE,
                    layout: Layout::Packed12,
                };
                (frame, 1_000_000 * (index as i64 + 1))
            });
            Ok(Some(take(whole)))
        }
    }

    // Each record written, whole.
    #[derive(Default)]
    struct Collected(Mutex<Vec<Vec<u8>>>);

    impl Records for Collected {
        fn write(&self, parts: &[&[u8]]) -> io::Result<()> {
            self.0.lock().unwrap().push(parts.concat());
            Ok(())
        }
    }

    // `count` frames of the same scene, a little brighter each time, the
    // frame at `incomplete` incomplete.
    fn scenes(count: usize, incomplete: Option<usize>) -> Vec<Option<Vec<u8>>> {
        (0..count)
            .map(|index| {
                let samples: Vec<u16> = samples(WIDTH, HEIGHT)
                    .iter()
                    .map(|sample| (sample + 150 * index as u16).min(4095))
                    .collect();
                (Some(index) != incomplete).then(|| padded_packed12(&samples, WIDTH, STRIDE))
            })
            .collect()
    }

    // One output of the test frames' size, converted by the processor.
    const FULL: OutputSpec = OutputSpec {
        source: Source::Cpu(Output::Full),
        width: WIDTH as u32,
        height: HEIGHT as u32,
        format: Format::Rgb,
        send: true,
    };

    // The frame loop over `frames` from the IMX477, writing to `records`,
    // logging its statistics every `statistics_every`.
    fn run_loop(
        frames: &TestFrames,
        input: &mut File,
        records: &impl Records,
        statistics_every: Duration,
    ) -> io::Result<()> {
        run_outputs(&[FULL], frames, input, records, statistics_every)
    }

    // `run_loop` making `outputs`.
    fn run_outputs(
        outputs: &[OutputSpec],
        frames: &TestFrames,
        input: &mut File,
        records: &impl Records,
        statistics_every: Duration,
    ) -> io::Result<()> {
        run_encoded(
            outputs,
            Vec::new(),
            frames,
            input,
            records,
            statistics_every,
        )
    }

    // `run_outputs` with `encoders` for its H.264 outputs.
    fn run_encoded(
        outputs: &[OutputSpec],
        encoders: Vec<Box<dyn Encoder>>,
        frames: &TestFrames,
        input: &mut File,
        records: &impl Records,
        statistics_every: Duration,
    ) -> io::Result<()> {
        let setup = Setup {
            outputs: outputs.to_vec(),
            model: SensorModel::Imx477,
            frame_us: 28_571.0,
            settings: ColourSettings::for_sensor(SensorModel::Imx477),
            statistics_every,
            encoders,
        };
        let set_exposure = |exposure_us: f64, gain: f64| Ok((exposure_us.round(), gain));
        capture(setup, frames, &set_exposure, input, records)
    }

    // The records the frame loop writes for `frames` from the IMX477.
    fn captured(
        frames: Vec<Option<Vec<u8>>>,
        settings: Vec<(usize, &'static str)>,
    ) -> Vec<Vec<u8>> {
        captured_as(&[FULL], frames, settings)
    }

    // `captured` making `outputs`.
    fn captured_as(
        outputs: &[OutputSpec],
        frames: Vec<Option<Vec<u8>>>,
        settings: Vec<(usize, &'static str)>,
    ) -> Vec<Vec<u8>> {
        let (frames, mut input) = TestFrames::new(frames, settings);
        let records = Collected::default();
        let hour = Duration::from_secs(3_600);
        run_outputs(outputs, &frames, &mut input, &records, hour).unwrap();
        records.0.into_inner().unwrap()
    }

    const OUTPUT_FRAME: u8 = 7;
    const METADATA: u8 = 3;

    // The images of the output `index`'s records, in order.
    fn output_images(records: &[Vec<u8>], index: u8) -> Vec<Vec<u8>> {
        let frames = records
            .iter()
            .filter(|record| record[..2] == [OUTPUT_FRAME, index]);
        frames.map(|record| record[14..].to_vec()).collect()
    }

    // FNV-1a of each record's length then bytes, in order.
    fn records_digest(records: &[Vec<u8>]) -> u64 {
        records
            .iter()
            .flat_map(|record| {
                (record.len() as u32)
                    .to_be_bytes()
                    .into_iter()
                    .chain(record.iter().copied())
            })
            .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
                (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3)
            })
    }

    #[test]
    fn a_sequence_of_frames_gives_the_same_records_in_the_same_order() {
        let records = captured(scenes(12, Some(5)), vec![]);
        let tags: Vec<u8> = records.iter().map(|record| record[0]).collect();
        // Frames (7), each fourth whole one after the exposure it sets (3).
        assert_eq!(tags, [7, 7, 7, 3, 7, 7, 7, 7, 3, 7, 7, 7, 7]);
        assert!(records
            .iter()
            .all(|record| record[0] != 7 || record[1] == 0));
        // Which thread writes the records changes none of them nor their order.
        assert_eq!(records_digest(&records), 0xd4ba9e80010111ea);
    }

    #[test]
    fn a_frame_gives_one_record_per_output_in_their_order() {
        let half = OutputSpec {
            source: Source::From(0),
            width: WIDTH as u32 / 2,
            height: HEIGHT as u32 / 2,
            format: Format::Rgb,
            send: true,
        };
        let full = captured(scenes(6, Some(2)), vec![]);
        let records = captured_as(&[FULL, half], scenes(6, Some(2)), vec![]);

        // Each frame's outputs (7) in order, the fourth's after the exposure it sets (3).
        let heads: Vec<(u8, u8)> = (records.iter())
            .map(|record| {
                (
                    record[0],
                    if record[0] == OUTPUT_FRAME {
                        record[1]
                    } else {
                        0
                    },
                )
            })
            .collect();
        let frame = [(7, 0), (7, 1)];
        let expected = [&frame[..], &frame, &frame, &[(3, 0)], &frame, &frame].concat();
        assert_eq!(heads, expected);
        assert_eq!(output_images(&records, 0), output_images(&full, 0));
        for (view, small) in output_images(&records, 0)
            .iter()
            .zip(output_images(&records, 1))
        {
            let mut averaged = Vec::new();
            scale::Averager::default().average_blocks(view, WIDTH, (2, 2), 1, &mut averaged);
            assert!(small == averaged);
        }
        for record in records.iter().filter(|record| record[0] == OUTPUT_FRAME) {
            let size = (
                u16::from_le_bytes([record[2], record[3]]),
                u16::from_le_bytes([record[4], record[5]]),
            );
            let expected = [(24, 46), (12, 23)][usize::from(record[1])];
            assert_eq!(size, expected);
            assert_eq!(
                record.len(),
                14 + 24 * 46 * 3 / [1, 4][usize::from(record[1])]
            );
        }
    }

    #[test]
    fn each_output_made_from_another_is_the_average_of_its_source() {
        let from = |source, width, height| OutputSpec {
            source: Source::From(source),
            width,
            height,
            format: Format::Rgb,
            send: true,
        };
        // The first 2x2 average of the CPU output is made as it converts,
        // the others after it.
        let outputs = [
            FULL,
            from(0, 12, 23),
            from(0, 12, 23),
            from(0, 12, 46),
            from(1, 6, 23),
        ];
        let records = captured_as(&outputs, scenes(6, None), vec![(2, "rotation=180")]);
        let images: Vec<_> = (0..outputs.len())
            .map(|index| output_images(&records, index as u8))
            .collect();
        for (index, spec) in outputs.iter().enumerate().skip(1) {
            let Source::From(source) = spec.source else {
                unreachable!()
            };
            let block = spec.block(&outputs[source]);
            assert_eq!(images[index].len(), 6);
            for (image, source_image) in images[index].iter().zip(&images[source]) {
                let mut averaged = Vec::new();
                let width = outputs[source].width as usize;
                scale::Averager::default().average_blocks(
                    source_image,
                    width,
                    block,
                    1,
                    &mut averaged,
                );
                assert!(*image == averaged, "output {index}");
            }
        }
    }

    #[test]
    fn each_output_a_processor_makes_has_the_image_of_its_own_size() {
        let half = OutputSpec {
            source: Source::Cpu(Output::Half),
            width: WIDTH as u32 / 2,
            height: HEIGHT as u32 / 2,
            format: Format::Rgb,
            send: true,
        };
        let full = captured(scenes(6, None), vec![]);
        let half_alone = captured_as(&[half], scenes(6, None), vec![]);
        let both = captured_as(&[half, FULL], scenes(6, None), vec![]);

        assert_eq!(output_images(&both, 0), output_images(&half_alone, 0));
        assert_eq!(output_images(&both, 1), output_images(&full, 0));
    }

    const OUTPUT_JPEG: u8 = 8;

    // An output scaled from the output `source`, as `format`.
    fn from(source: usize, (width, height): (usize, usize), format: Format) -> OutputSpec {
        OutputSpec {
            source: Source::From(source),
            width: width as u32,
            height: height as u32,
            format,
            send: true,
        }
    }

    // The JPEGs of the output `index`'s records, in order.
    fn output_jpegs(records: &[Vec<u8>], index: u8) -> Vec<Vec<u8>> {
        let jpegs = records
            .iter()
            .filter(|record| record[..2] == [OUTPUT_JPEG, index]);
        jpegs.map(|record| record[14..].to_vec()).collect()
    }

    // A JPEG's size and RGB pixels.
    fn decoded(jpeg: &[u8]) -> (usize, usize, Vec<u8>) {
        let image = turbojpeg::decompress(jpeg, turbojpeg::PixelFormat::RGB).unwrap();
        (image.width, image.height, image.pixels)
    }

    fn psnr(decoded: &[u8], expected: &[u8]) -> f64 {
        assert_eq!(decoded.len(), expected.len());
        let squared: f64 = (decoded.iter().zip(expected))
            .map(|(a, b)| (f64::from(*a) - f64::from(*b)).powi(2))
            .sum();
        10.0 * (255.0f64.powi(2) / (squared / decoded.len() as f64)).log10()
    }

    // The index of the image of `images` closest to `decoded`, and its PSNR.
    fn closest(decoded: &[u8], images: &[Vec<u8>]) -> (usize, f64) {
        (images.iter().map(|image| psnr(decoded, image)).enumerate())
            .max_by(|a, b| a.1.total_cmp(&b.1))
            .unwrap()
    }

    #[test]
    fn each_jpeg_decodes_to_the_image_of_its_own_frame() {
        let (width, height) = (WIDTH, HEIGHT);
        let outputs = [
            FULL,
            from(0, (width, height), Format::Jpeg { quality: 80 }),
            from(0, (width / 2, height / 2), Format::Jpeg { quality: 95 }),
        ];
        let records = captured_as(&outputs, scenes(8, None), vec![]);
        let views = output_images(&records, 0);
        let halves: Vec<Vec<u8>> = (views.iter())
            .map(|view| {
                let mut half = Vec::new();
                scale::Averager::default().average_blocks(view, width, (2, 2), 1, &mut half);
                half
            })
            .collect();

        for (index, expected, size) in [
            (1, &views, (width, height)),
            (2, &halves, (width / 2, height / 2)),
        ] {
            let jpegs = output_jpegs(&records, index);
            assert_eq!(jpegs.len(), 8);
            for (frame, jpeg) in jpegs.iter().enumerate() {
                let (jpeg_width, jpeg_height, rgb) = decoded(jpeg);
                assert_eq!((jpeg_width, jpeg_height), size);
                let (closest, decibels) = closest(&rgb, expected);
                assert_eq!(closest, frame, "output {index}");
                assert!(
                    decibels > 30.0,
                    "output {index} frame {frame}: {decibels} dB"
                );
            }
        }
    }

    #[test]
    fn a_frame_gives_its_jpeg_record_in_the_order_of_its_outputs() {
        let half = (WIDTH / 2, HEIGHT / 2);
        let rgb_only = [FULL, from(0, half, Format::Rgb)];
        let outputs = [
            FULL,
            from(0, (WIDTH, HEIGHT), Format::Jpeg { quality: 80 }),
            from(0, half, Format::Rgb),
        ];
        let without = captured_as(&rgb_only, scenes(6, Some(2)), vec![]);
        let records = captured_as(&outputs, scenes(6, Some(2)), vec![]);

        // Each frame's outputs in order, the fourth's after the exposure it sets (3).
        let heads: Vec<(u8, u8)> = (records.iter())
            .map(|record| match record[0] {
                OUTPUT_FRAME | OUTPUT_JPEG => (record[0], record[1]),
                tag => (tag, 0),
            })
            .collect();
        let frame = [(7, 0), (8, 1), (7, 2)];
        let expected = [&frame[..], &frame, &frame, &[(3, 0)], &frame, &frame].concat();
        assert_eq!(heads, expected);
        let frame_records: Vec<&Vec<u8>> = (records.iter())
            .filter(|record| [OUTPUT_FRAME, OUTPUT_JPEG].contains(&record[0]))
            .collect();
        for outputs in frame_records.chunks(3) {
            let starts: Vec<&[u8]> = outputs.iter().map(|record| &record[6..14]).collect();
            assert!(starts.iter().all(|start| *start == starts[0]));
        }
        let size = |record: &Vec<u8>| (record[2..4].to_vec(), record[4..6].to_vec());
        let jpeg_record = records.iter().find(|record| record[0] == OUTPUT_JPEG);
        assert_eq!(
            jpeg_record.map(size),
            Some((vec![WIDTH as u8, 0], vec![HEIGHT as u8, 0]))
        );
        assert_eq!(output_images(&records, 0), output_images(&without, 0));
        assert_eq!(output_images(&records, 2), output_images(&without, 1));
    }

    #[test]
    fn an_unsent_output_gives_no_record_and_the_others_theirs_in_order() {
        let half = (WIDTH / 2, HEIGHT / 2);
        let sent = [
            FULL,
            from(0, (WIDTH, HEIGHT), Format::Jpeg { quality: 80 }),
            from(0, half, Format::Rgb),
            from(0, (WIDTH / 3, HEIGHT / 2), Format::Rgb),
        ];
        let unsent = OutputSpec {
            send: false,
            ..FULL
        };
        let mut outputs = sent;
        outputs[0] = unsent;
        let all = captured_as(&sent, scenes(6, Some(2)), vec![]);
        let records = captured_as(&outputs, scenes(6, Some(2)), vec![]);

        // Each frame's sent outputs, with their indices, the fourth's after the exposure it sets (3).
        let heads: Vec<(u8, u8)> = (records.iter())
            .map(|record| match record[0] {
                OUTPUT_FRAME | OUTPUT_JPEG => (record[0], record[1]),
                tag => (tag, 0),
            })
            .collect();
        let frame = [(8, 1), (7, 2), (7, 3)];
        let expected = [&frame[..], &frame, &frame, &[(3, 0)], &frame, &frame].concat();
        assert_eq!(heads, expected);
        // What is made from it is what is made from it sent.
        let made = |records: &[Vec<u8>]| -> Vec<Vec<u8>> {
            (records.iter())
                .filter(|record| [OUTPUT_FRAME, OUTPUT_JPEG].contains(&record[0]))
                .filter(|record| record[1] != 0)
                .cloned()
                .collect()
        };
        assert!(made(&records) == made(&all));
    }

    #[test]
    fn a_setting_sent_while_frames_arrive_applies_from_the_next_frame() {
        let upright = captured(scenes(8, None), vec![]);
        let turned = captured(scenes(8, None), vec![(2, "rotation=180")]);
        let frames = |records: &[Vec<u8>]| -> Vec<Vec<u8>> { output_images(records, 0) };
        let turn =
            |rgb: &[u8]| -> Vec<u8> { rgb.chunks_exact(3).rev().flatten().copied().collect() };
        let (upright, turned_frames) = (frames(&upright), frames(&turned));

        assert_eq!(turned_frames.len(), 8);
        assert_eq!(turned_frames[..3], upright[..3]);
        for (turned, upright) in turned_frames[3..].iter().zip(&upright[3..]) {
            assert!(*turned == turn(upright));
        }
        let applied = turned
            .iter()
            .position(|record| record.starts_with(b"\x02\x00settings: "));
        let third_frame = (turned.iter().enumerate())
            .filter(|(_, record)| record[0] == OUTPUT_FRAME)
            .nth(2)
            .map(|(position, _)| position);
        assert_eq!(applied, third_frame.map(|position| position + 1));
    }

    // The value in `slot` of a metadata record.
    fn metadata_value(record: &[u8], slot: usize) -> f64 {
        let start = 10 + 8 * slot;
        f64::from_le_bytes(record[start..start + 8].try_into().unwrap())
    }

    // The exposure and gain of a metadata record.
    fn exposure_of(record: &[u8]) -> (f64, f64) {
        (metadata_value(record, 0), metadata_value(record, 1))
    }

    #[test]
    fn a_lowered_exposure_cap_applies_with_the_setting() {
        let records = captured(scenes(4, None), vec![(1, "max_exposure_us=1000")]);
        let applied = records
            .iter()
            .position(|record| record.starts_with(b"\x02\x00settings: "))
            .unwrap();
        let capped = records[..applied]
            .iter()
            .rev()
            .find(|record| record[..2] == [METADATA, 0b11])
            .map(|record| exposure_of(record));

        assert_eq!(capped, Some((1_000.0, 16.0)));
    }

    // Holds the first frame's first record of the tag `held` until the loop
    // takes the next frame, two seconds at most, and tells whether it did.
    struct Held {
        held: u8,
        taken: Mutex<mpsc::Receiver<usize>>,
        overlapped: Mutex<Option<bool>>,
    }

    impl Records for Held {
        fn write(&self, parts: &[&[u8]]) -> io::Result<()> {
            let mut overlapped = self.overlapped.lock().unwrap();
            if parts[0][0] == self.held && overlapped.is_none() {
                let taken = self.taken.lock().unwrap();
                let mut taken =
                    std::iter::from_fn(|| taken.recv_timeout(Duration::from_secs(2)).ok());
                *overlapped = Some(taken.any(|index| index == 1));
            }
            Ok(())
        }
    }

    #[test]
    fn a_frame_is_written_while_the_next_one_converts() {
        let (mut frames, mut input) = TestFrames::new(scenes(3, None), vec![]);
        let (on_take, taken) = mpsc::channel();
        frames.on_take = Some(on_take);
        let records = Held {
            held: OUTPUT_FRAME,
            taken: Mutex::new(taken),
            overlapped: Mutex::new(None),
        };
        let hour = Duration::from_secs(3_600);
        run_loop(&frames, &mut input, &records, hour).unwrap();
        assert_eq!(*records.overlapped.lock().unwrap(), Some(true));
    }

    #[test]
    fn a_frame_s_jpeg_is_written_while_the_next_one_converts() {
        let outputs = [FULL, from(0, (WIDTH, HEIGHT), Format::Jpeg { quality: 80 })];
        let (mut frames, mut input) = TestFrames::new(scenes(3, None), vec![]);
        let (on_take, taken) = mpsc::channel();
        frames.on_take = Some(on_take);
        let records = Held {
            held: OUTPUT_JPEG,
            taken: Mutex::new(taken),
            overlapped: Mutex::new(None),
        };
        let hour = Duration::from_secs(3_600);
        run_outputs(&outputs, &frames, &mut input, &records, hour).unwrap();
        assert_eq!(*records.overlapped.lock().unwrap(), Some(true));
    }

    // Takes `frames` frame records, then fails as a closed pipe does.
    struct Closing {
        frames: AtomicUsize,
    }

    impl Records for Closing {
        fn write(&self, parts: &[&[u8]]) -> io::Result<()> {
            if parts[0][0] != OUTPUT_FRAME {
                return Ok(());
            }
            let left = self.frames.fetch_sub(1, Ordering::SeqCst);
            if left == 0 {
                self.frames.store(0, Ordering::SeqCst);
                return Err(io::ErrorKind::BrokenPipe.into());
            }
            Ok(())
        }
    }

    #[test]
    fn the_loop_stops_with_the_error_of_a_write() {
        let (frames, mut input) = TestFrames::new(scenes(12, None), vec![]);
        let records = Closing {
            frames: AtomicUsize::new(3),
        };
        let hour = Duration::from_secs(3_600);
        let error = run_loop(&frames, &mut input, &records, hour).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
        assert!(frames.taken.get() < 12);
    }

    #[test]
    fn the_loop_stops_with_the_error_of_an_encode() {
        // A quality the command line refuses, and the encoder too.
        let outputs = [FULL, from(0, (WIDTH, HEIGHT), Format::Jpeg { quality: 0 })];
        let (frames, mut input) = TestFrames::new(scenes(12, None), vec![]);
        let records = Collected::default();
        let hour = Duration::from_secs(3_600);
        let error = run_outputs(&outputs, &frames, &mut input, &records, hour).unwrap_err();
        let message = error.to_string();
        assert!(!message.contains("thread stopped"), "{message}");
        assert!(frames.taken.get() < 12);
    }

    #[test]
    fn the_statistics_give_the_time_a_frame_takes_to_write() {
        let (frames, mut input) = TestFrames::new(scenes(4, None), vec![]);
        let records = Collected::default();
        run_loop(&frames, &mut input, &records, Duration::ZERO).unwrap();
        let records = records.0.into_inner().unwrap();
        let statistics = records.iter().filter_map(|record| {
            let message = record.strip_prefix(b"\x02\x00last ")?;
            Some(String::from_utf8(message.to_vec()).unwrap())
        });
        assert!(statistics.clone().count() > 0);
        assert!(
            statistics
                .clone()
                .all(|line| line.contains(" us per write")),
            "{:?}",
            statistics.collect::<Vec<_>>()
        );
    }

    #[test]
    fn the_statistics_give_the_time_a_jpeg_takes_to_encode() {
        let outputs = [FULL, from(0, (WIDTH, HEIGHT), Format::Jpeg { quality: 80 })];
        let (frames, mut input) = TestFrames::new(scenes(6, None), vec![]);
        let records = Collected::default();
        run_outputs(&outputs, &frames, &mut input, &records, Duration::ZERO).unwrap();
        let records = records.0.into_inner().unwrap();
        let encodes: Vec<u64> = (records.iter())
            .filter_map(|record| {
                let message = String::from_utf8(record.strip_prefix(b"\x02\x00last ")?.to_vec());
                let message = message.unwrap();
                let (before, _) = message.split_once(" us per JPEG encode")?;
                before.rsplit(' ').next()?.parse().ok()
            })
            .collect();
        assert!(encodes.len() > 1, "{encodes:?}");
        assert!(encodes.iter().any(|&us| us > 0), "{encodes:?}");
    }

    // A 2028 x 1520 frame as a JPEG at quality 80.
    #[test]
    #[ignore = "a benchmark: run with `-- --ignored --nocapture` to print the host's times"]
    fn host_time_of_a_full_frame_encoded_as_a_jpeg() {
        let (width, height) = (2028, 1520);
        let stride = width * 3 / 2;
        let raw = padded_packed12(&samples(width, height), width, stride);
        let frame = RawFrame {
            raw: &raw,
            width,
            height,
            row_stride: stride,
            layout: Layout::Packed12,
        };
        let conversion = Conversion {
            output: Output::Full,
            rotate_180: false,
            channel_means: false,
            green_mean: false,
            row_step: MEASURED_ROW_STEP,
            threads: 3,
        };
        let mut rgb = Vec::new();
        let images = Images {
            rgb: &mut rgb,
            averaged: None,
            nv12: None,
        };
        develop_along(
            Path::Denoised,
            &frame,
            &conversion,
            images,
            &mut Default::default(),
        );
        // A smooth scene too: the test frame's noise makes the encoder's work heavier.
        let smooth: Vec<u8> = (0..width * height)
            .flat_map(|pixel| {
                let (x, y) = (pixel % width, pixel / width);
                [(x / 8) as u8, (y / 6) as u8, ((x + y) / 14) as u8]
            })
            .collect();
        let mut compressor = turbojpeg::Compressor::new().unwrap();
        for (scene, pixels) in [("converted noise", &rgb), ("smooth", &smooth)] {
            let mut times = Vec::new();
            let mut length = 0;
            for _ in 0..30 {
                let started = Instant::now();
                length = jpeg::encode(&mut compressor, pixels, (width, height), 80)
                    .unwrap()
                    .len();
                times.push(started.elapsed());
            }
            times.sort();
            println!(
                "{scene}: median {:?}, fastest {:?}, {length} bytes",
                times[times.len() / 2],
                times[0]
            );
        }
    }

    const OUTPUT_H264: u8 = 9;

    // Gives each frame's NV12 back as its stream, a key frame every third
    // frame, nothing for the frame at `skip`, and an error at `fail_at`.
    struct FakeEncoder {
        layout: Nv12Layout,
        frames: usize,
        skip: Option<usize>,
        fail_at: Option<usize>,
    }

    // The test frames' NV12, in rows of 32 bytes, chroma after 48 rows.
    const TEST_LAYOUT: Nv12Layout = Nv12Layout {
        width: WIDTH,
        height: HEIGHT,
        stride: 32,
        luma_rows: 48,
        size: 32 * 48 * 3 / 2,
    };

    fn fake_encoder(skip: Option<usize>, fail_at: Option<usize>) -> Box<dyn Encoder> {
        Box::new(FakeEncoder {
            layout: TEST_LAYOUT,
            frames: 0,
            skip,
            fail_at,
        })
    }

    impl Encoder for FakeEncoder {
        fn layout(&self) -> Nv12Layout {
            self.layout
        }

        fn encode(&mut self, nv12: &[u8], capture_ns: i64) -> io::Result<Option<EncodedFrame>> {
            let frame = self.frames;
            self.frames += 1;
            if self.fail_at == Some(frame) {
                return Err(io::Error::other("the encoder failed"));
            }
            Ok((self.skip != Some(frame)).then(|| EncodedFrame {
                capture_ns,
                key_frame: frame.is_multiple_of(3),
                bytes: nv12.to_vec(),
                took: Duration::from_micros(250),
            }))
        }

        fn stop(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    const H264: Format = Format::H264 {
        bitrate_kbps: 4_000,
        keyframe_interval: 3,
    };

    // The records the frame loop writes for `frames` making `outputs`, its
    // H.264 outputs through `encoders`.
    fn captured_encoded(
        outputs: &[OutputSpec],
        encoders: Vec<Box<dyn Encoder>>,
        frames: Vec<Option<Vec<u8>>>,
    ) -> Vec<Vec<u8>> {
        let (frames, mut input) = TestFrames::new(frames, vec![]);
        let records = Collected::default();
        let hour = Duration::from_secs(3_600);
        run_encoded(outputs, encoders, &frames, &mut input, &records, hour).unwrap();
        records.0.into_inner().unwrap()
    }

    #[test]
    fn each_h264_frame_is_a_record_of_its_own_frame_in_the_order_of_the_outputs() {
        let outputs = [
            FULL,
            from(0, (WIDTH, HEIGHT), Format::Jpeg { quality: 80 }),
            from(0, (WIDTH, HEIGHT), H264),
            from(0, (WIDTH / 2, HEIGHT / 2), Format::Rgb),
        ];
        let records =
            captured_encoded(&outputs, vec![fake_encoder(None, None)], scenes(6, Some(2)));

        // Each frame's outputs in order, the fourth's after the exposure it sets (3).
        let heads: Vec<(u8, u8)> = (records.iter())
            .map(|record| match record[0] {
                OUTPUT_FRAME | OUTPUT_JPEG | OUTPUT_H264 => (record[0], record[1]),
                tag => (tag, 0),
            })
            .collect();
        let frame = [(7, 0), (8, 1), (9, 2), (7, 3)];
        let expected = [&frame[..], &frame, &frame, &[(3, 0)], &frame, &frame].concat();
        assert_eq!(heads, expected);
        let views = output_images(&records, 0);
        let videos: Vec<&Vec<u8>> = (records.iter())
            .filter(|record| record[0] == OUTPUT_H264)
            .collect();
        let starts: Vec<&[u8]> = (records.iter())
            .filter(|record| record[..2] == [OUTPUT_FRAME, 0])
            .map(|record| &record[6..14])
            .collect();
        assert_eq!(videos.len(), 5);
        for (frame, video) in videos.iter().enumerate() {
            assert_eq!(video[2..6], [WIDTH as u8, 0, HEIGHT as u8, 0]);
            assert_eq!(&video[6..14], starts[frame]);
            assert_eq!(video[14], u8::from(frame % 3 == 0), "frame {frame}");
            let mut nv12 = vec![0; TEST_LAYOUT.size];
            nv12::convert(&views[frame], &TEST_LAYOUT, 1, &mut nv12);
            assert!(video[15..] == nv12, "frame {frame}");
        }
    }

    #[test]
    fn a_frame_the_encoder_gives_nothing_for_has_no_h264_record() {
        let outputs = [FULL, from(0, (WIDTH, HEIGHT), H264)];
        let records =
            captured_encoded(&outputs, vec![fake_encoder(Some(1), None)], scenes(3, None));
        let heads: Vec<(u8, u8)> = (records.iter())
            .filter(|record| record[0] != 3)
            .map(|record| (record[0], record[1]))
            .collect();
        assert_eq!(heads, [(7, 0), (9, 1), (7, 0), (7, 0), (9, 1)]);
    }

    #[test]
    fn the_loop_stops_with_the_error_of_an_h264_encode() {
        let outputs = [FULL, from(0, (WIDTH, HEIGHT), H264)];
        let (frames, mut input) = TestFrames::new(scenes(12, None), vec![]);
        let records = Collected::default();
        let hour = Duration::from_secs(3_600);
        let encoders = vec![fake_encoder(None, Some(2))];
        let error =
            run_encoded(&outputs, encoders, &frames, &mut input, &records, hour).unwrap_err();
        assert_eq!(error.to_string(), "the encoder failed");
        assert!(frames.taken.get() < 12);
    }

    #[test]
    fn the_statistics_give_the_nv12_conversion_the_h264_encode_and_its_bytes() {
        let outputs = [FULL, from(0, (WIDTH, HEIGHT), H264)];
        let (frames, mut input) = TestFrames::new(scenes(6, None), vec![]);
        let records = Collected::default();
        let encoders = vec![fake_encoder(None, None)];
        run_encoded(
            &outputs,
            encoders,
            &frames,
            &mut input,
            &records,
            Duration::ZERO,
        )
        .unwrap();
        let records = records.0.into_inner().unwrap();
        let lines: Vec<String> = (records.iter())
            .filter_map(|record| {
                let message = record.strip_prefix(b"\x02\x00last ")?;
                Some(String::from_utf8(message.to_vec()).unwrap())
            })
            .collect();
        let figure = |line: &str, unit: &str| -> u64 {
            let (before, _) = line.split_once(unit).unwrap();
            before.rsplit(' ').next().unwrap().parse().unwrap()
        };
        assert!(lines.len() > 1, "{lines:?}");
        let written = lines.iter().filter(|line| {
            figure(line, " us per H.264 encode") == 250
                && figure(line, " bytes per s of H.264") % TEST_LAYOUT.size as u64 == 0
                && figure(line, " bytes per s of H.264") > 0
        });
        assert!(written.count() > 0, "{lines:?}");
        assert!(
            (lines.iter()).all(|line| line.contains(" us per NV12 conversion")),
            "{lines:?}"
        );
    }

    #[test]
    fn the_statistics_give_no_scaling_time_when_the_conversion_averages() {
        let half = OutputSpec {
            source: Source::From(0),
            width: WIDTH as u32 / 2,
            height: HEIGHT as u32 / 2,
            format: Format::Rgb,
            send: true,
        };
        let (frames, mut input) = TestFrames::new(scenes(4, None), vec![]);
        let records = Collected::default();
        run_outputs(&[FULL, half], &frames, &mut input, &records, Duration::ZERO).unwrap();
        let records = records.0.into_inner().unwrap();
        let statistics: Vec<_> = (records.iter())
            .filter_map(|record| {
                let message = record.strip_prefix(b"\x02\x00last ")?;
                Some(String::from_utf8(message.to_vec()).unwrap())
            })
            .collect();
        assert!(statistics.len() > 1);
        assert!(
            (statistics.iter()).all(|line| line.contains(", 0 us per scaling")),
            "{statistics:?}"
        );
    }
}
