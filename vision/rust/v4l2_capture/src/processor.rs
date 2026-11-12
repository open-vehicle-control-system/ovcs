//! What makes a camera output from the sensor's raw frame: a processor.
//! `Cpu` is the software conversion; an output scaled from another one is
//! made after the processors (`scale`).

use crate::arguments::Output;
use crate::bands::{Conversion, Images, Measures};
use crate::bayer::{self, RawFrame, Tone};
use crate::colour::{self, Colour, ContrastTable};
use crate::sensor::SensorModel;
use crate::settings::ColourSettings;
use crate::tuning::Tuning;
use crate::white_balance::Gains;

/// White balance and auto exposure measure every this many rows of RGGB
/// cells, the same cells whatever the output's size.
pub const MEASURED_ROW_STEP: usize = 4;

/// Makes an output from each raw frame.
pub trait Processor: Send {
    /// `frame` as `development` says, into `images`, with what it asks to
    /// measure.
    fn develop(&mut self, frame: &RawFrame, development: &Development, images: Images) -> Measures;
}

/// How a frame is developed, as the settings stand when it comes.
pub struct Development<'a> {
    pub settings: &'a ColourSettings,
    /// The white balance gains in force.
    pub gains: Gains,
    /// The tone of a sensor without a tuning.
    pub tone: &'a Tone,
    /// Measures the channel means white balance takes.
    pub channel_means: bool,
    /// Measures the green auto exposure steers.
    pub green_mean: bool,
    /// The threads the frame is converted on.
    pub threads: usize,
}

/// The software conversion at the size of `output`: a sensor's colour
/// path when it has a tuning, its gamma otherwise.
pub struct Cpu {
    output: Output,
    tuned: Option<TunedColour>,
    buffers: colour::Buffers,
    fallback_buffers: bayer::Buffers,
}

impl Cpu {
    pub fn new(model: SensorModel, output: Output) -> Cpu {
        Cpu {
            output,
            tuned: model.tuning().map(TunedColour::new),
            buffers: colour::Buffers::default(),
            fallback_buffers: bayer::Buffers::default(),
        }
    }
}

impl Processor for Cpu {
    fn develop(&mut self, frame: &RawFrame, development: &Development, images: Images) -> Measures {
        let settings = development.settings;
        let conversion = Conversion {
            output: self.output,
            rotate_180: settings.capture.rotation == 180,
            channel_means: development.channel_means,
            green_mean: development.green_mean,
            row_step: MEASURED_ROW_STEP,
            threads: development.threads,
        };
        match &self.tuned {
            Some(tuned) => develop_tuned(
                frame,
                &conversion,
                settings,
                development.gains,
                tuned,
                images,
                &mut self.buffers,
            ),
            None => bayer::develop(
                frame,
                development.tone,
                development.gains,
                &conversion,
                images,
                &mut self.fallback_buffers,
            ),
        }
    }
}

/// A sensor's tuning, and the table of its contrast curve.
pub struct TunedColour {
    pub tuning: &'static Tuning,
    contrast: ContrastTable,
}

impl TunedColour {
    pub fn new(tuning: &'static Tuning) -> TunedColour {
        TunedColour {
            tuning,
            contrast: ContrastTable::new(tuning),
        }
    }
}

/// `raw` through `tuned`'s colour path as `conversion` asks, into `images`
/// through `buffers`, at the colour temperature of `gains`, with the colour
/// correction matrix and the chroma denoise as `settings` switch them.
pub fn develop_tuned(
    raw: &RawFrame,
    conversion: &Conversion,
    settings: &ColourSettings,
    gains: Gains,
    tuned: &TunedColour,
    images: Images,
    buffers: &mut colour::Buffers,
) -> Measures {
    let kelvin = tuned.tuning.colour_temperature(gains);
    let shading = tuned.tuning.lens_shading(kelvin);
    let colour = Colour {
        black_level: settings.capture.black_level,
        shading: &shading,
        white_balance: gains,
        matrix: if settings.ccm {
            tuned.tuning.colour_matrix(kelvin)
        } else {
            colour::IDENTITY
        },
        contrast: &tuned.contrast,
        denoise: settings.denoise,
    };
    colour::develop(raw, &colour, conversion, images, buffers)
}
