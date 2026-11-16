//! The lens shading gains of the colour path.

use super::GAIN_SHIFT;
use crate::tuning::LensShading;

/// Interpolation weights between shading vertices are in 1/256ths.
pub(super) const WEIGHT_SHIFT: u32 = 8;
const WEIGHT_ONE: u32 = 1 << WEIGHT_SHIFT;

/// The gain of each sample of a frame, in 1/4096ths, bilinear between gains
/// at the vertices of a grid over the frame.
#[derive(Default)]
pub(super) struct ShadingGains {
    columns: usize,
    rows: usize,
    height: usize,
    vertices: [Vec<u32>; 3],
    /// Each sample column's vertex on its left, and the weight of the one on
    /// its right.
    column_vertex: Vec<usize>,
    column_weight: Vec<u32>,
    /// The gains at the vertices of a sample row's two channels, between the
    /// vertex rows above and below it.
    row_vertices: [Vec<u32>; 2],
}

impl ShadingGains {
    /// The gains of `shading`, each channel's times `channel_gains`, each at
    /// most `cap`, on a frame of `width` by `height` samples.
    #[cfg(test)]
    pub(super) fn new(
        shading: &LensShading,
        channel_gains: [f64; 3],
        cap: u32,
        width: usize,
        height: usize,
    ) -> ShadingGains {
        let mut gains = ShadingGains::default();
        gains.set(shading, channel_gains, cap, width, height);
        gains
    }

    /// Becomes the gains `new` gives, in the rows it already holds.
    pub(super) fn set(
        &mut self,
        shading: &LensShading,
        channel_gains: [f64; 3],
        cap: u32,
        width: usize,
        height: usize,
    ) {
        for (channel, vertices) in self.vertices.iter_mut().enumerate() {
            vertices.clear();
            vertices.extend(shading.gains[channel].iter().map(|gain| {
                (gain * channel_gains[channel] * f64::from(1u32 << GAIN_SHIFT))
                    .round()
                    .min(f64::from(cap)) as u32
            }));
        }
        self.column_vertex.clear();
        self.column_weight.clear();
        for column in 0..width {
            let (vertex, weight) = vertex_and_weight(column, width, shading.columns - 1);
            self.column_vertex.push(vertex);
            self.column_weight.push(weight);
        }
        for row_vertices in &mut self.row_vertices {
            row_vertices.resize(shading.columns, 0);
        }
        (self.columns, self.rows, self.height) = (shading.columns, shading.rows, height);
    }

    /// Fills `gains` with the gain of each sample of row `row`: red's and
    /// green's on an even row, green's and blue's on an odd one.
    pub(super) fn row(&mut self, row: usize, gains: &mut [u32]) {
        let (above, weight) = vertex_and_weight(row, self.height, self.rows - 1);
        let channels = if row.is_multiple_of(2) {
            [0, 1]
        } else {
            [1, 2]
        };
        for (row_vertices, channel) in self.row_vertices.iter_mut().zip(channels) {
            let vertices = &self.vertices[channel];
            let top = &vertices[above * self.columns..(above + 1) * self.columns];
            let bottom = &vertices[(above + 1) * self.columns..(above + 2) * self.columns];
            for ((gain, &top), &bottom) in row_vertices.iter_mut().zip(top).zip(bottom) {
                *gain = (top * (WEIGHT_ONE - weight) + bottom * weight) >> WEIGHT_SHIFT;
            }
        }
        let [even, odd] = &self.row_vertices;
        let between = |vertices: &[u32], left: usize, weight: u32| {
            (vertices[left] * (WEIGHT_ONE - weight) + vertices[left + 1] * weight) >> WEIGHT_SHIFT
        };
        for ((pair, left), weight) in gains
            .chunks_exact_mut(2)
            .zip(self.column_vertex.chunks_exact(2))
            .zip(self.column_weight.chunks_exact(2))
        {
            pair[0] = between(even, left[0], weight[0]);
            pair[1] = between(odd, left[1], weight[1]);
        }
    }
}

/// The vertex before the centre of sample `index` of `count` on a grid of
/// `cells` cells over them, and the weight of the vertex after it.
fn vertex_and_weight(index: usize, count: usize, cells: usize) -> (usize, u32) {
    let position = (((2 * index + 1) * cells) << WEIGHT_SHIFT) / (2 * count);
    (
        position >> WEIGHT_SHIFT,
        (position as u32) & (WEIGHT_ONE - 1),
    )
}
