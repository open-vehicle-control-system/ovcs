//! A run of consecutive stages of `VisionCore.Stereo.Pipeline` computed
//! natively: the counterpart of `VisionCore.Stereo.NxSegment`. It is
//! configured once with each stage's kind and build settings, keeps what
//! depends only on them and the inputs it last saw (rectification maps,
//! matching buffers) and what stages carry from one pair to the next, and
//! runs each pair through every stage in order on named tensors.

use std::collections::HashMap;
use std::time::Instant;

use crate::depth::{self, Intrinsics};
use crate::filters::{self, Temporal, TemporalSettings};
use crate::measures::{self, Quality, BANDS, PLANES};
use crate::rectify::{self, Camera, Map};
use crate::tensor::{f32_map, u8_image, Data, Tensor, Tensors};
use crate::{Matcher, Params};

/// The sizes every stage works with: the rectified images' and the
/// submitted frames'.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    pub width: usize,
    pub height: usize,
    pub frame_width: usize,
    pub frame_height: usize,
}

/// A stage's build settings, its `options/1` values.
pub type Options = HashMap<String, f64>;
/// A stage's live inputs for one pair, its `params/2` values as `f32`.
pub type Inputs = HashMap<String, Vec<f32>>;
/// The tensors a run filled, by name, and each stage's time in microseconds.
pub type Outputs = (Vec<(String, Tensor)>, Vec<u32>);

enum Stage {
    Rectification {
        maps: Box<[Option<(Camera, Map)>; 2]>,
    },
    Sharpness,
    Disparity {
        disparities: usize,
        paths: u8,
        matcher: Box<Matcher>,
    },
    MedianFilter {
        kernel_size: usize,
    },
    SpeckleFilter,
    RowAlignment,
    TemporalFilter(Temporal),
    Depth,
    PointCloud {
        decimation: usize,
    },
    Quality(Quality),
}

pub struct Segment {
    geometry: Geometry,
    threads: usize,
    stages: Vec<Stage>,
}

/// The tensors each stage fills: what a run returns, once each.
fn outputs(stage: &Stage) -> &'static [&'static str] {
    match stage {
        Stage::Rectification { .. } => &["left", "right"],
        Stage::Sharpness => &["sharpness_sums"],
        Stage::Disparity { .. }
        | Stage::MedianFilter { .. }
        | Stage::SpeckleFilter
        | Stage::TemporalFilter(_) => &["disparity"],
        Stage::RowAlignment => &["alignment_sums"],
        Stage::Depth => &["depth_mm", "depth_m"],
        Stage::PointCloud { .. } => &["cloud_grid", "cloud_points"],
        Stage::Quality(_) => &["quality_sums"],
    }
}

fn option(options: &Options, kind: &str, name: &str) -> Result<f64, String> {
    options
        .get(name)
        .copied()
        .ok_or_else(|| format!("{kind} needs its {name} setting"))
}

fn input<'a>(inputs: &'a Inputs, name: &str, len: usize) -> Result<&'a [f32], String> {
    match inputs.get(name) {
        Some(values) if values.len() == len => Ok(values),
        Some(values) => Err(format!(
            "{name} has {} values, expected {len}",
            values.len()
        )),
        None => Err(format!("no {name} among the stage's inputs")),
    }
}

fn scalar(inputs: &Inputs, name: &str) -> Result<f32, String> {
    input(inputs, name, 1).map(|values| values[0])
}

/// A penalty, an integer `NxStereo.sgm/3` takes as a byte.
fn penalty(inputs: &Inputs, name: &str) -> Result<u8, String> {
    let value = scalar(inputs, name)?;
    if value.fract() == 0.0 && (0.0..=255.0).contains(&value) {
        Ok(value as u8)
    } else {
        Err(format!(
            "{name} must be an integer from 0 to 255, got {value}"
        ))
    }
}

fn camera(inputs: &Inputs, side: &str) -> Result<Camera, String> {
    let values = |name: &str, len| input(inputs, &format!("{side}.{name}"), len);
    Ok(Camera {
        k: values("k", 9)?.try_into().unwrap(),
        d: values("d", 5)?.try_into().unwrap(),
        inverse_pr: values("inverse_pr", 9)?.try_into().unwrap(),
    })
}

fn integer_option(
    options: &Options,
    kind: &str,
    name: &str,
    allowed: &[usize],
) -> Result<usize, String> {
    let value = option(options, kind, name)?;
    allowed
        .iter()
        .copied()
        .find(|&allowed| allowed as f64 == value)
        .ok_or_else(|| format!("{kind} {name} must be one of {allowed:?}, got {value}"))
}

impl Segment {
    /// A segment of `members`, each a stage kind (its name in the pipeline)
    /// and its build settings, run on `threads` threads.
    pub fn new(
        geometry: Geometry,
        members: &[(String, Options)],
        threads: usize,
    ) -> Result<Segment, String> {
        if geometry.width < 2 || geometry.height < 2 {
            return Err(format!("a segment works at 2x2 or more, got {geometry:?}"));
        }
        let pixels = geometry.width * geometry.height;
        let stages = members
            .iter()
            .map(|(kind, options)| {
                Ok(match kind.as_str() {
                    "rectification" => Stage::Rectification {
                        maps: Box::new([None, None]),
                    },
                    "sharpness" => Stage::Sharpness,
                    "disparity" => {
                        let disparities = integer_option(options, kind, "num_disparities", &[64, 128])?;
                        let paths = integer_option(options, kind, "paths", &[3, 8])? as u8;
                        let params = Params { disparities, paths, p1: 8, p2: 64, uniqueness: 1.0 };
                        params.check(geometry.width, geometry.height)?;
                        Stage::Disparity { disparities, paths, matcher: Box::new(Matcher::new(threads)) }
                    }
                    "median_filter" => Stage::MedianFilter {
                        kernel_size: integer_option(options, kind, "kernel_size", &[3, 5])?,
                    },
                    "speckle_filter" => Stage::SpeckleFilter,
                    "row_alignment" => Stage::RowAlignment,
                    "temporal_filter" => Stage::TemporalFilter(Temporal::new(pixels)),
                    "depth" => Stage::Depth,
                    "point_cloud" => {
                        let decimation = option(options, kind, "decimation")?;
                        let largest = geometry.width.min(geometry.height) as f64;
                        if !(decimation.fract() == 0.0 && (1.0..=largest).contains(&decimation)) {
                            return Err(format!("point_cloud decimation must be an integer from 1 to {largest}, got {decimation}"));
                        }
                        Stage::PointCloud { decimation: decimation as usize }
                    }
                    "quality" => Stage::Quality(Quality::new(pixels)),
                    other => return Err(format!("no native implementation of {other}")),
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(Segment {
            geometry,
            threads: threads.max(1),
            stages,
        })
    }

    /// Runs `tensors` through every stage, `inputs` holding each stage's
    /// live inputs in order. Returns the tensors the stages filled, by name,
    /// and each stage's time in microseconds.
    pub fn run(&mut self, inputs: &[Inputs], mut tensors: Tensors) -> Result<Outputs, String> {
        if inputs.len() != self.stages.len() {
            return Err(format!(
                "{} stages, got the inputs of {}",
                self.stages.len(),
                inputs.len()
            ));
        }
        let mut filled: Vec<&'static str> = Vec::new();
        let mut times_us = Vec::with_capacity(self.stages.len());
        for (stage, inputs) in self.stages.iter_mut().zip(inputs) {
            let start = Instant::now();
            run_stage(stage, &self.geometry, self.threads, inputs, &mut tensors)?;
            times_us.push(u32::try_from(start.elapsed().as_micros()).unwrap_or(u32::MAX));
            for name in outputs(stage) {
                if !filled.contains(name) {
                    filled.push(name);
                }
            }
        }
        let outputs = filled
            .into_iter()
            .map(|name| {
                (
                    name.to_string(),
                    tensors.remove(name).expect("a stage fills its outputs"),
                )
            })
            .collect();
        Ok((outputs, times_us))
    }
}

fn run_stage(
    stage: &mut Stage,
    geometry: &Geometry,
    threads: usize,
    inputs: &Inputs,
    tensors: &mut Tensors,
) -> Result<(), String> {
    let (width, height) = (geometry.width, geometry.height);
    let size = [height, width];
    let image = |data: Data| Tensor::new(size.to_vec(), data);
    match stage {
        Stage::Rectification { maps } => {
            let frame_shape = [geometry.frame_height, geometry.frame_width];
            for (side, map) in ["left", "right"].into_iter().zip(maps.iter_mut()) {
                let camera = camera(inputs, side)?;
                if map.as_ref().is_none_or(|(cached, _map)| *cached != camera) {
                    let built = Map::new(
                        &camera,
                        (width, height),
                        (geometry.frame_width, geometry.frame_height),
                    );
                    *map = Some((camera, built));
                }
            }
            let left_frame = u8_image(tensors, "left_frame", frame_shape)?;
            let right_frame = u8_image(tensors, "right_frame", frame_shape)?;
            let (mut left, mut right) = (vec![0; width * height], vec![0; width * height]);
            let [Some((_, left_map)), Some((_, right_map))] = &**maps else {
                unreachable!()
            };
            rectify::rectify_pair(
                [left_map, right_map],
                [left_frame, right_frame],
                geometry.frame_width,
                [&mut left, &mut right],
                threads,
            );
            tensors.insert("left".into(), image(Data::U8(left)));
            tensors.insert("right".into(), image(Data::U8(right)));
        }
        Stage::Sharpness => {
            let sums = measures::sharpness_sums(
                u8_image(tensors, "left", size)?,
                u8_image(tensors, "right", size)?,
                width,
            );
            tensors.insert(
                "sharpness_sums".into(),
                Tensor::new(vec![5], Data::F32(sums.to_vec())),
            );
        }
        Stage::Disparity {
            disparities,
            paths,
            matcher,
        } => {
            let params = Params {
                disparities: *disparities,
                paths: *paths,
                p1: penalty(inputs, "p1")?,
                p2: penalty(inputs, "p2")?,
                uniqueness: scalar(inputs, "uniqueness")?,
            };
            params.check(width, height)?;
            let disparity = matcher.disparity(
                u8_image(tensors, "left", size)?,
                u8_image(tensors, "right", size)?,
                width,
                height,
                &params,
            );
            tensors.insert("disparity".into(), image(Data::F32(disparity)));
        }
        Stage::MedianFilter { kernel_size } => {
            let filtered = filters::median(
                f32_map(tensors, "disparity", size)?,
                width,
                height,
                *kernel_size,
                threads,
            );
            tensors.insert("disparity".into(), image(Data::F32(filtered)));
        }
        Stage::SpeckleFilter => {
            let filtered = filters::despeckle(
                f32_map(tensors, "disparity", size)?,
                width,
                height,
                scalar(inputs, "min_support")?,
                scalar(inputs, "max_diff")?,
                threads,
            );
            tensors.insert("disparity".into(), image(Data::F32(filtered)));
        }
        Stage::RowAlignment => {
            let sums = measures::alignment_sums(
                u8_image(tensors, "left", size)?,
                u8_image(tensors, "right", size)?,
                f32_map(tensors, "disparity", size)?,
                width,
                height,
            );
            let flat = sums.iter().flatten().copied().collect();
            tensors.insert(
                "alignment_sums".into(),
                Tensor::new(vec![BANDS, PLANES], Data::F32(flat)),
            );
        }
        Stage::TemporalFilter(temporal) => {
            let settings = TemporalSettings {
                alpha: scalar(inputs, "alpha")?,
                delta: scalar(inputs, "delta")?,
                hold: scalar(inputs, "hold")?,
            };
            f32_map(tensors, "disparity", size)?;
            let Some(Tensor {
                data: Data::F32(disparity),
                ..
            }) = tensors.get_mut("disparity")
            else {
                unreachable!()
            };
            temporal.filter(disparity, &settings);
        }
        Stage::Depth => {
            let (depth_mm, depth_m) = depth::depth(
                f32_map(tensors, "disparity", size)?,
                width,
                scalar(inputs, "focal_length_px")?,
                scalar(inputs, "baseline_m")?,
                threads,
            );
            tensors.insert("depth_mm".into(), image(Data::U16(depth_mm)));
            tensors.insert("depth_m".into(), image(Data::F32(depth_m)));
        }
        Stage::PointCloud { decimation } => {
            let intrinsics = Intrinsics {
                focal_length_px: scalar(inputs, "focal_length_px")?,
                cx: scalar(inputs, "cx")?,
                cy: scalar(inputs, "cy")?,
            };
            let (points, kept) = depth::cloud(
                f32_map(tensors, "depth_m", size)?,
                width,
                height,
                *decimation,
                &intrinsics,
            );
            let grid = vec![height / *decimation, width / *decimation, 3];
            tensors.insert("cloud_grid".into(), Tensor::new(grid, Data::F32(points)));
            tensors.insert(
                "cloud_points".into(),
                Tensor::new(vec![], Data::S32(vec![kept as i32])),
            );
        }
        Stage::Quality(quality) => {
            let sums = quality.sums(f32_map(tensors, "disparity", size)?, width);
            tensors.insert(
                "quality_sums".into(),
                Tensor::new(vec![5], Data::F32(sums.to_vec())),
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn geometry() -> Geometry {
        Geometry {
            width: 32,
            height: 24,
            frame_width: 32,
            frame_height: 24,
        }
    }

    fn options(values: &[(&str, f64)]) -> Options {
        values
            .iter()
            .map(|&(name, value)| (name.to_string(), value))
            .collect()
    }

    #[test]
    fn refuses_unknown_kinds_and_settings() {
        let refused = |kind: &str, values: &[(&str, f64)]| {
            Segment::new(geometry(), &[(kind.to_string(), options(values))], 2)
                .err()
                .unwrap()
        };
        assert!(refused("decode", &[]).contains("no native implementation of decode"));
        assert!(refused("median_filter", &[("kernel_size", 7.0)]).contains("[3, 5]"));
        assert!(refused("disparity", &[("num_disparities", 64.0)]).contains("paths"));
        assert!(refused("point_cloud", &[("decimation", 0.0)]).contains("decimation"));
    }

    #[test]
    fn returns_each_filled_tensor_once_with_its_last_value() {
        let geometry = geometry();
        let members = [
            (
                "median_filter".to_string(),
                options(&[("kernel_size", 3.0)]),
            ),
            ("depth".to_string(), Options::new()),
            ("speckle_filter".to_string(), Options::new()),
        ];
        let mut segment = Segment::new(geometry, &members, 2).unwrap();
        let inputs: Vec<Inputs> = vec![
            Inputs::new(),
            [("focal_length_px", 100.0), ("baseline_m", 0.1)]
                .map(|(name, value)| (name.to_string(), vec![value]))
                .into(),
            [("min_support", 49.0), ("max_diff", 1.0)]
                .map(|(name, value)| (name.to_string(), vec![value]))
                .into(),
        ];
        let disparity = Tensor::new(vec![24, 32], Data::F32(vec![10.0; 32 * 24]));
        let tensors = Tensors::from([("disparity".to_string(), disparity)]);
        let (outputs, times) = segment.run(&inputs, tensors).unwrap();
        let names: Vec<&str> = outputs.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(names, ["disparity", "depth_mm", "depth_m"]);
        assert_eq!(times.len(), 3);
        assert_eq!(outputs[0].1.data, Data::F32(vec![-1.0; 32 * 24]));
        assert_eq!(outputs[1].1.data, Data::U16(vec![1000; 32 * 24]));
    }

    #[test]
    fn says_which_input_is_missing_or_of_the_wrong_shape() {
        let members = [("depth".to_string(), Options::new())];
        let mut segment = Segment::new(geometry(), &members, 1).unwrap();
        let wrong = Tensor::new(vec![2, 2], Data::F32(vec![0.0; 4]));
        let error = segment
            .run(
                &[Inputs::new()],
                Tensors::from([("disparity".to_string(), wrong)]),
            )
            .unwrap_err();
        assert!(error.contains("expected a [24, 32] f32 map"), "{error}");
    }
}
