//! A single colour camera: captures its raw RGGB frames, demosaics them at
//! the capture's size or each 2x2 cell into one pixel, with grey-world white
//! balance, runs auto exposure on the green of the RGGB cells as the image
//! tones it, and writes RGB_FRAME records on stdout, each frame converted in
//! bands of rows on as many threads as `threads` sets and written on a
//! writer thread while the next one converts. A sensor with a tuning
//! takes its colour path (`colour`): lens shading, white balance, the colour
//! correction matrix of its colour temperature, the chroma denoise and the
//! contrast curve; another one its gamma.

use std::fs::File;
use std::io;
use std::os::fd::{AsFd, AsRawFd, RawFd};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use framing::{log_record, metadata_record, rgb_frame_header, LogLevel, Writer};

use crate::arguments::{Output, SingleArguments};
use crate::bayer::{RawFrame, Tone};
use crate::processor::{Cpu, Development, Processor};
use crate::sensor::{self, SensorModel};
use crate::settings::ColourSettings;
use crate::v4l2;
use crate::white_balance;
use crate::{
    auto_exposure, auto_exposure_from, input, open_camera, pollfd, resume_point,
    EXPOSURE_EVERY_FRAMES, EXPOSURE_GAIN_PRESENT, EXPOSURE_MARGIN_LINES, STATISTICS_EVERY_S,
};

/// Captures the camera `arguments` names at its full sensor size until the
/// host closes stdin, writing each frame at the size of `arguments.output`.
pub fn run(
    arguments: &SingleArguments,
    writer: &Writer,
    log: &dyn Fn(LogLevel, &str),
) -> io::Result<()> {
    let (sensor_width, sensor_height) = (arguments.sensor_width, arguments.sensor_height);
    let (width, height) = arguments.output.size(sensor_width, sensor_height);
    let model = SensorModel::for_sensor(&arguments.camera.sensor);
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
            "{sensor_width}x{sensor_height} {:?} to {width}x{height} {:?}, line {line_ns:.1} ns, \
             vblank {vblank}, period {period_ns} ns, {settings:?}",
            camera.capture.layout, arguments.output
        ),
    );
    let frames = CameraFrames {
        capture: &camera.capture,
        width: sensor_width as usize,
        height: sensor_height as usize,
    };
    let setup = Setup {
        output: arguments.output,
        model,
        frame_us,
        settings,
        statistics_every: Duration::from_secs(STATISTICS_EVERY_S),
    };
    let mut input = input::unbuffered(io::stdin().as_fd())?;
    capture(setup, &frames, &set_exposure, &mut input, writer)
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
    output: Output,
    model: SensorModel,
    /// A frame's period.
    frame_us: f64,
    settings: ColourSettings,
    /// How often the statistics are logged.
    statistics_every: Duration,
}

/// Converts the frames of `frames` as `setup` says and writes them to
/// `records`, each on a writer thread while the next one converts,
/// steering the sensor's exposure through `set_exposure` and applying the
/// settings `input` sends, until `input` closes. The records keep the order
/// they are sent in.
fn capture(
    setup: Setup,
    frames: &impl Frames,
    set_exposure: &dyn Fn(f64, f64) -> io::Result<(f64, f64)>,
    input: &mut File,
    records: &impl Records,
) -> io::Result<()> {
    std::thread::scope(|scope| {
        let (sender, queued) = mpsc::channel();
        let (written, images) = mpsc::channel();
        let writer = scope.spawn(move || write_records(records, queued, written));
        let queue = Queue {
            records: sender,
            images,
        };
        let converted = convert_frames(setup, frames, set_exposure, input, &queue);
        drop(queue);
        let written = writer
            .join()
            .unwrap_or_else(|panic| std::panic::resume_unwind(panic));
        // After a failed write the loop's own error only says the writer stopped.
        written.and(converted)
    })
}

/// A record for the writer thread: a frame's header and image, or another
/// record whole.
enum Record {
    Frame([u8; 13], Vec<u8>),
    Other(Vec<u8>),
}

/// Writes each record `queued` holds to `records`, in order, handing each
/// frame's image back to `written` with the time its write took.
fn write_records(
    records: &impl Records,
    queued: mpsc::Receiver<Record>,
    written: mpsc::Sender<(Vec<u8>, Duration)>,
) -> io::Result<()> {
    for record in queued {
        match record {
            Record::Frame(header, image) => {
                let writing = Instant::now();
                records.write(&[&header, &image])?;
                let _ = written.send((image, writing.elapsed()));
            }
            Record::Other(record) => records.write(&[&record])?,
        }
    }
    Ok(())
}

/// The records on their way to the writer thread, and the images it has
/// written on their way back.
struct Queue {
    records: mpsc::Sender<Record>,
    images: mpsc::Receiver<(Vec<u8>, Duration)>,
}

impl Queue {
    fn send(&self, record: Record) -> io::Result<()> {
        self.records.send(record).map_err(|_| writer_stopped())
    }

    /// The next image written, waiting for its write to end, and the time
    /// it took.
    fn written(&self) -> io::Result<(Vec<u8>, Duration)> {
        self.images.recv().map_err(|_| writer_stopped())
    }
}

fn writer_stopped() -> io::Error {
    io::Error::other("the writer thread stopped")
}

/// `capture`'s loop, sending its records to `queue`.
fn convert_frames(
    setup: Setup,
    frames: &impl Frames,
    set_exposure: &dyn Fn(f64, f64) -> io::Result<(f64, f64)>,
    input: &mut File,
    queue: &Queue,
) -> io::Result<()> {
    let Setup {
        output,
        model,
        frame_us,
        mut settings,
        statistics_every,
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
    let mut processor = Cpu::new(model, output);
    // Two images alternate: one converts while the writer writes the other.
    let (mut rgb, mut spare) = (Vec::new(), Some(Vec::new()));
    let mut tone = tone_for(&settings);
    let mut gains = settings.gains();
    let mut auto_exposure = auto_exposure(&settings.capture, frame_us);
    let mut last_ns = None;

    let mut converted = 0u32;
    // Frames converted, and frames dropped as incomplete.
    let mut statistics = [0u64; 2];
    let mut conversion_ns = 0u128;
    let (mut writes, mut write_ns) = (0u64, 0u128);
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
            match framing::read_record(input)? {
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
                        log(LogLevel::Info, &format!("settings: {settings:?}"));
                    }
                    Err(message) => log(LogLevel::Warning, &message),
                },
            }
        }
        if statistics_since.elapsed() >= statistics_every {
            log(
                LogLevel::Info,
                &format!(
                    "last {} s: frames {}, incomplete {}, \
                     {} us per conversion, {} us per write, white balance {gains:?}{}",
                    statistics_every.as_secs(),
                    statistics[0],
                    statistics[1],
                    conversion_ns / 1_000 / u128::from(statistics[0].max(1)),
                    write_ns / 1_000 / u128::from(writes.max(1)),
                    tuning
                        .map(|tuning| format!(", {:.0} K", tuning.colour_temperature(gains)))
                        .unwrap_or_default()
                ),
            );
            statistics = [0; 2];
            conversion_ns = 0;
            (writes, write_ns) = (0, 0);
            statistics_since = Instant::now();
        }
        // One frame a round: the settings and statistics are served between frames.
        if let Some(taken) = frames.next(|whole| {
            let (raw, start_ns) = whole?;
            let converting = Instant::now();
            converted += 1;
            let measure_exposure =
                settings.capture.auto_exposure && converted.is_multiple_of(EXPOSURE_EVERY_FRAMES);
            let development = Development {
                settings: &settings,
                gains,
                tone: &tone,
                channel_means: settings.awb,
                green_mean: measure_exposure,
                threads: settings.threads.unwrap_or(output.threads()),
            };
            let developed = processor.develop(&raw, &development, &mut rgb);
            if let Some(means) = developed.channel_means {
                gains = white_balance::grey_world(means, gains);
            }
            conversion_ns += converting.elapsed().as_nanos();
            Some((start_ns, raw.width, raw.height, developed.green_mean))
        })? {
            let Some((start_ns, sensor_width, sensor_height, green_mean)) = taken else {
                statistics[1] += 1;
                continue;
            };
            statistics[0] += 1;
            last_ns = Some(start_ns);
            if let Some(mean) = green_mean {
                if let Some((exposure_us, gain)) = auto_exposure.observe(mean) {
                    let applied = set_exposure(exposure_us, gain)?;
                    queue.send(Record::Other(exposure_record(applied, start_ns)))?;
                }
            }
            let free = match spare.take() {
                Some(image) => image,
                None => {
                    let (image, took) = queue.written()?;
                    (writes, write_ns) = (writes + 1, write_ns + took.as_nanos());
                    image
                }
            };
            let (width, height) = output.size(sensor_width as u32, sensor_height as u32);
            let header = rgb_frame_header(width as u16, height as u16, start_ns);
            queue.send(Record::Frame(header, std::mem::replace(&mut rgb, free)))?;
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
    use crate::bands::{Conversion, Measures};
    use crate::bayer::Layout;
    use crate::bayer::{self, tests::padded_packed12};
    use crate::colour;
    use crate::processor::{develop_tuned, TunedColour, MEASURED_ROW_STEP};
    use crate::tuning::imx477;
    use crate::white_balance::Gains;

    // Noise over a gradient down and across, so that every row differs.
    fn samples(width: usize, height: usize) -> Vec<u16> {
        let mut state = 0x2545_f491u32;
        (0..width * height)
            .map(|i| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                let (x, y) = (i % width, i / width);
                let gradient = (y * 2400 / height + x * 600 / width) as u32;
                (200 + gradient + state % 900).min(4095) as u16
            })
            .collect()
    }

    // The image and measures of a frame, the means as bits to compare exactly.
    type Outcome = (Vec<u8>, Option<[u64; 3]>, Option<u64>);

    fn outcome(rgb: &[u8], measures: Measures) -> Outcome {
        (
            rgb.to_vec(),
            measures.channel_means.map(|means| means.map(f64::to_bits)),
            measures.green_mean.map(f64::to_bits),
        )
    }

    // FNV-1a of a frame's image, then of its means' bits.
    fn digest(rgb: &[u8], measures: Measures) -> u64 {
        let means = measures.channel_means.into_iter().flatten();
        let bits = means
            .chain(measures.green_mean)
            .flat_map(|mean| mean.to_bits().to_le_bytes());
        rgb.iter()
            .copied()
            .chain(bits)
            .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
                (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3)
            })
    }

    #[derive(Clone, Copy, Debug)]
    enum Path {
        Denoised,
        Undenoised,
        Untuned,
    }

    #[test]
    fn a_frame_converts_to_the_same_image_and_measures_on_any_number_of_threads() {
        let tuned = TunedColour::new(&imx477::TUNING);
        let tone = Tone::with_sample_bits(256, 2.2, 12);
        let gains = Gains {
            red: 2.1,
            blue: 1.6,
        };
        // The digests of the conversion on one thread before it was split
        // into bands.
        #[rustfmt::skip]
        let pinned = [
            ((24, 46), Output::Full, false, Path::Denoised, 0x5adc1b5784f7a6df),
            ((24, 46), Output::Full, false, Path::Undenoised, 0x77d9d3238a8e2a9a),
            ((24, 46), Output::Full, false, Path::Untuned, 0xfa1d284195545234),
            ((24, 46), Output::Full, true, Path::Denoised, 0xabd2abe75c2af1e9),
            ((24, 46), Output::Full, true, Path::Undenoised, 0xe02c8e3b04a8abca),
            ((24, 46), Output::Full, true, Path::Untuned, 0xbe584640e4e37f70),
            ((24, 46), Output::Half, false, Path::Denoised, 0xa4169b1baac71cf3),
            ((24, 46), Output::Half, false, Path::Undenoised, 0x7c01efd2f3ddbcbb),
            ((24, 46), Output::Half, false, Path::Untuned, 0x1a25c91807e49859),
            ((24, 46), Output::Half, true, Path::Denoised, 0xd1bc07eb69191829),
            ((24, 46), Output::Half, true, Path::Undenoised, 0x60b1c77294f02b35),
            ((24, 46), Output::Half, true, Path::Untuned, 0xd813e5060cc7f6bf),
            ((36, 6), Output::Full, false, Path::Denoised, 0x896da32606cabe67),
            ((36, 6), Output::Full, false, Path::Undenoised, 0x23424f1951fbf106),
            ((36, 6), Output::Full, false, Path::Untuned, 0x02d67db56bc545df),
            ((36, 6), Output::Full, true, Path::Denoised, 0x4619a8a968ff5bb3),
            ((36, 6), Output::Full, true, Path::Undenoised, 0xdb2ebcc5fada1634),
            ((36, 6), Output::Full, true, Path::Untuned, 0x1a4a7bf9f48e8f87),
            ((36, 6), Output::Half, false, Path::Denoised, 0xd44a33ae59ed2d90),
            ((36, 6), Output::Half, false, Path::Undenoised, 0x986243c7ea2645f1),
            ((36, 6), Output::Half, false, Path::Untuned, 0x6d2b63032f973687),
            ((36, 6), Output::Half, true, Path::Denoised, 0x4e39a53de350fc12),
            ((36, 6), Output::Half, true, Path::Undenoised, 0xe68e692b564a01c9),
            ((36, 6), Output::Half, true, Path::Untuned, 0x3f58b52486d9842b),
        ];
        for ((width, height), output, rotate_180, path, expected) in pinned {
            let stride = width * 3 / 2 + 6;
            let raw = padded_packed12(&samples(width, height), width, stride);
            let frame = RawFrame {
                raw: &raw,
                width,
                height,
                row_stride: stride,
                layout: Layout::Packed12,
            };
            let settings = ColourSettings {
                denoise: !matches!(path, Path::Undenoised),
                ..ColourSettings::default()
            };
            for threads in 1..=4 {
                let conversion = Conversion {
                    output,
                    rotate_180,
                    channel_means: true,
                    green_mean: true,
                    row_step: MEASURED_ROW_STEP,
                    threads,
                };
                let mut rgb = Vec::new();
                let measures = match path {
                    Path::Untuned => bayer::develop(
                        &frame,
                        &tone,
                        gains,
                        &conversion,
                        &mut rgb,
                        &mut bayer::Buffers::default(),
                    ),
                    _ => develop_tuned(
                        &frame,
                        &conversion,
                        &settings,
                        gains,
                        &tuned,
                        &mut rgb,
                        &mut colour::Buffers::default(),
                    ),
                };
                assert_eq!(
                    digest(&rgb, measures),
                    expected,
                    "{width}x{height} {output:?} rotated {rotate_180} {path:?} on {threads} threads"
                );
            }
        }
    }

    #[test]
    fn a_frame_converted_on_several_threads_is_the_one_converted_on_one() {
        let tuned = TunedColour::new(&imx477::TUNING);
        let tone = Tone::with_sample_bits(256, 2.2, 12);
        let gains = Gains {
            red: 2.1,
            blue: 1.6,
        };
        // 23, 25 and 11 rows of RGGB cells split unevenly in 2, 3 and 4 bands;
        // 3 rows give a fourth thread no band.
        for (width, height) in [(24, 46), (24, 50), (32, 22), (36, 6)] {
            let stride = width * 3 / 2 + 6;
            let raw = padded_packed12(&samples(width, height), width, stride);
            let frame = RawFrame {
                raw: &raw,
                width,
                height,
                row_stride: stride,
                layout: Layout::Packed12,
            };
            for output in [Output::Full, Output::Half] {
                for rotate_180 in [false, true] {
                    for (denoise, ccm) in [(true, true), (false, true), (true, false)] {
                        let settings = ColourSettings {
                            denoise,
                            ccm,
                            ..ColourSettings::default()
                        };
                        let (mut rgb, mut buffers, mut fallback) = (
                            Vec::new(),
                            colour::Buffers::default(),
                            bayer::Buffers::default(),
                        );
                        let mut developed = |threads| {
                            let conversion = Conversion {
                                output,
                                rotate_180,
                                channel_means: true,
                                green_mean: true,
                                row_step: MEASURED_ROW_STEP,
                                threads,
                            };
                            let measures = develop_tuned(
                                &frame,
                                &conversion,
                                &settings,
                                gains,
                                &tuned,
                                &mut rgb,
                                &mut buffers,
                            );
                            let tuned = outcome(&rgb, measures);
                            let measures = bayer::develop(
                                &frame,
                                &tone,
                                gains,
                                &conversion,
                                &mut rgb,
                                &mut fallback,
                            );
                            (tuned, outcome(&rgb, measures))
                        };
                        let one = developed(1);
                        for threads in [2, 3, 4, 3, 1] {
                            assert!(
                                developed(threads) == one,
                                "{width}x{height} {output:?} rotated {rotate_180} \
                                 denoise {denoise} ccm {ccm} on {threads} threads"
                            );
                        }
                    }
                }
            }
        }
    }

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

    // The frame loop over `frames` from the IMX477, writing to `records`,
    // logging its statistics every `statistics_every`.
    fn run_loop(
        frames: &TestFrames,
        input: &mut File,
        records: &impl Records,
        statistics_every: Duration,
    ) -> io::Result<()> {
        let setup = Setup {
            output: Output::Full,
            model: SensorModel::Imx477,
            frame_us: 28_571.0,
            settings: ColourSettings::default(),
            statistics_every,
        };
        let set_exposure = |exposure_us: f64, gain: f64| Ok((exposure_us.round(), gain));
        capture(setup, frames, &set_exposure, input, records)
    }

    // The records the frame loop writes for `frames` from the IMX477.
    fn captured(
        frames: Vec<Option<Vec<u8>>>,
        settings: Vec<(usize, &'static str)>,
    ) -> Vec<Vec<u8>> {
        let (frames, mut input) = TestFrames::new(frames, settings);
        let records = Collected::default();
        let hour = Duration::from_secs(3_600);
        run_loop(&frames, &mut input, &records, hour).unwrap();
        records.0.into_inner().unwrap()
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
        // Frames (6), each fourth whole one after the exposure it sets (3).
        assert_eq!(tags, [6, 6, 6, 3, 6, 6, 6, 6, 3, 6, 6, 6, 6]);
        // Which thread writes the records changes none of them nor their order.
        assert_eq!(records_digest(&records), 0xf88a5dbe53ea288a);
    }

    #[test]
    fn a_setting_sent_while_frames_arrive_applies_from_the_next_frame() {
        let upright = captured(scenes(8, None), vec![]);
        let turned = captured(scenes(8, None), vec![(2, "rotation=180")]);
        let frames = |records: &[Vec<u8>]| -> Vec<Vec<u8>> {
            let frames = records.iter().filter(|record| record[0] == 6);
            frames.map(|record| record[13..].to_vec()).collect()
        };
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
            .filter(|(_, record)| record[0] == 6)
            .nth(2)
            .map(|(position, _)| position);
        assert_eq!(applied, third_frame.map(|position| position + 1));
    }

    // Holds the first frame's record until the loop takes the next frame,
    // two seconds at most, and tells whether it did.
    struct Held {
        taken: Mutex<mpsc::Receiver<usize>>,
        overlapped: Mutex<Option<bool>>,
    }

    impl Records for Held {
        fn write(&self, parts: &[&[u8]]) -> io::Result<()> {
            let mut overlapped = self.overlapped.lock().unwrap();
            if parts[0][0] == 6 && overlapped.is_none() {
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
            taken: Mutex::new(taken),
            overlapped: Mutex::new(None),
        };
        let hour = Duration::from_secs(3_600);
        run_loop(&frames, &mut input, &records, hour).unwrap();
        assert_eq!(*records.overlapped.lock().unwrap(), Some(true));
    }

    // Takes `frames` frame records, then fails as a closed pipe does.
    struct Closing {
        frames: AtomicUsize,
    }

    impl Records for Closing {
        fn write(&self, parts: &[&[u8]]) -> io::Result<()> {
            if parts[0][0] != 6 {
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
}
