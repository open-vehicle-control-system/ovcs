//! A sensor's colour tuning, and what libcamera's Raspberry Pi algorithms
//! derive from it for a colour temperature: the colour temperature of
//! white balance gains (`rpi.awb`), the colour correction matrix
//! (`rpi.ccm`), the lens shading gains (`rpi.alsc`, without its adaptive
//! step) and the contrast curve (`rpi.contrast`, without its histogram
//! stretch).

pub mod imx477;

use crate::white_balance::Gains;

/// The values of one sensor's tuning file for libcamera.
pub struct Tuning {
    /// Colour temperature in kelvin, then the red and the blue of a grey
    /// under that light, each over its green, in increasing temperature.
    pub colour_temperature_curve: &'static [[f64; 3]],
    /// In increasing temperature.
    pub colour_matrices: &'static [ColourMatrix],
    pub lens_shading: LensShadingTables,
    /// 16-bit linear input, then 16-bit output, in increasing input.
    pub contrast_curve: &'static [[u16; 2]],
}

/// A colour correction matrix, row-major: output red, green and blue from
/// input red, green and blue.
pub struct ColourMatrix {
    pub kelvin: f64,
    pub matrix: [f64; 9],
}

/// Lens shading gains per cell of a grid over the frame, row-major.
pub struct LensShadingTables {
    /// Whether the tables are in the order of the frame turned by 180
    /// degrees, as libcamera reads out a sensor its device tree turns.
    pub rotated_180: bool,
    pub columns: usize,
    pub rows: usize,
    /// Every channel's gain.
    pub luminance: &'static [f64],
    /// The share of `luminance` applied: 1 is all of it.
    pub luminance_strength: f64,
    /// Red's and blue's gains relative to green's, in increasing temperature.
    pub red: &'static [ColourShading],
    pub blue: &'static [ColourShading],
}

/// A colour's shading table calibrated under a light of `kelvin`.
pub struct ColourShading {
    pub kelvin: f64,
    pub table: &'static [f64],
}

/// Red's, green's and blue's lens shading gains at the vertices of a grid
/// over the frame, row-major, in the frame's readout order: the first
/// vertex at its top left corner, the last at its bottom right.
#[derive(Clone, Debug, PartialEq)]
pub struct LensShading {
    /// Vertices across, and down.
    pub columns: usize,
    pub rows: usize,
    pub gains: [Vec<f64>; 3],
}

impl Tuning {
    /// The colour temperature of the light white balance `gains` make grey,
    /// as `rpi.awb` finds it for manual gains: the mean of the temperatures
    /// at which the curve's red and its blue are those the gains bring to
    /// green's level, each within the curve.
    pub fn colour_temperature(&self, gains: Gains) -> f64 {
        let temperature_at = |channel: usize, gain: f64| {
            let mut points: Vec<[f64; 2]> = self
                .colour_temperature_curve
                .iter()
                .map(|point| [point[channel], point[0]])
                .collect();
            points.sort_by(|a, b| a[0].total_cmp(&b[0]));
            piecewise_linear(&points, 1.0 / gain)
        };
        (temperature_at(1, gains.red) + temperature_at(2, gains.blue)) / 2.0
    }

    /// The colour correction matrix at `kelvin`: interpolated between the
    /// two calibrated temperatures around it, the nearest one's beyond them.
    pub fn colour_matrix(&self, kelvin: f64) -> [f64; 9] {
        std::array::from_fn(|i| {
            let points: Vec<[f64; 2]> = self
                .colour_matrices
                .iter()
                .map(|calibrated| [calibrated.kelvin, calibrated.matrix[i]])
                .collect();
            piecewise_linear(&points, kelvin)
        })
    }

    /// The contrast curve's 16-bit output for a 16-bit linear `input`.
    pub fn contrast(&self, input: f64) -> f64 {
        let points: Vec<[f64; 2]> = self
            .contrast_curve
            .iter()
            .map(|&[x, y]| [f64::from(x), f64::from(y)])
            .collect();
        piecewise_linear(&points, input)
    }

    /// The lens shading gains at `kelvin`, as `rpi.alsc` sets them when it
    /// starts: the colour tables interpolated to `kelvin` and divided by
    /// their least gain, each times `luminance` at its strength, then
    /// resampled from cells to their corners as libcamera's PiSP pipeline
    /// does, each corner the mean of the cells it touches.
    pub fn lens_shading(&self, kelvin: f64) -> LensShading {
        let tables = &self.lens_shading;
        let luminance: Vec<f64> = tables
            .luminance
            .iter()
            .map(|gain| (gain - 1.0) * tables.luminance_strength + 1.0)
            .collect();
        let shaded = |calibrations: &[ColourShading]| -> Vec<f64> {
            let colour = colour_table_at(calibrations, kelvin, luminance.len());
            let least = colour.iter().copied().fold(f64::MAX, f64::min);
            colour
                .iter()
                .zip(&luminance)
                .map(|(gain, luminance)| gain / least * luminance)
                .collect()
        };
        let cells = [shaded(tables.red), luminance.clone(), shaded(tables.blue)];
        LensShading {
            columns: tables.columns + 1,
            rows: tables.rows + 1,
            gains: cells.map(|cells| {
                let mut vertices = cell_corners(&cells, tables.columns, tables.rows);
                if tables.rotated_180 {
                    vertices.reverse();
                }
                vertices
            }),
        }
    }
}

/// The value at `x` of the line through `points`, in increasing x: the
/// nearest end's beyond them.
fn piecewise_linear(points: &[[f64; 2]], x: f64) -> f64 {
    let (first, last) = (points[0], points[points.len() - 1]);
    if x <= first[0] {
        return first[1];
    }
    if x >= last[0] {
        return last[1];
    }
    let above = points
        .iter()
        .position(|point| point[0] >= x)
        .unwrap_or(points.len() - 1);
    let ([x0, y0], [x1, y1]) = (points[above - 1], points[above]);
    y0 + (y1 - y0) * (x - x0) / (x1 - x0)
}

/// A colour shading table at `kelvin`: interpolated between the two
/// calibrated temperatures around it, the nearest one beyond them, all 1
/// without calibrations.
fn colour_table_at(calibrations: &[ColourShading], kelvin: f64, cells: usize) -> Vec<f64> {
    let (Some(first), Some(last)) = (calibrations.first(), calibrations.last()) else {
        return vec![1.0; cells];
    };
    if kelvin <= first.kelvin {
        return first.table.to_vec();
    }
    if kelvin >= last.kelvin {
        return last.table.to_vec();
    }
    let above = calibrations
        .iter()
        .position(|calibration| calibration.kelvin >= kelvin)
        .unwrap_or(calibrations.len() - 1);
    let (low, high) = (&calibrations[above - 1], &calibrations[above]);
    let share = (kelvin - low.kelvin) / (high.kelvin - low.kelvin);
    low.table
        .iter()
        .zip(high.table)
        .map(|(low, high)| low * (1.0 - share) + high * share)
        .collect()
}

/// The values at the corners of a grid of `columns` by `rows` cells, each
/// the mean of the cells it touches.
fn cell_corners(cells: &[f64], columns: usize, rows: usize) -> Vec<f64> {
    let around = |corner: usize, count: usize| (corner.saturating_sub(1), corner.min(count - 1));
    let mut corners = Vec::with_capacity((columns + 1) * (rows + 1));
    for row in 0..=rows {
        let (above, below) = around(row, rows);
        for column in 0..=columns {
            let (left, right) = around(column, columns);
            let at = |row: usize, column: usize| cells[row * columns + column];
            corners.push(
                (at(above, left) + at(above, right) + at(below, left) + at(below, right)) / 4.0,
            );
        }
    }
    corners
}

impl LensShading {
    /// No shading: every gain 1, on a grid of one cell.
    #[cfg(test)]
    pub fn none() -> LensShading {
        LensShading {
            columns: 2,
            rows: 2,
            gains: std::array::from_fn(|_| vec![1.0; 4]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TUNING: &Tuning = &imx477::TUNING;

    fn gains_at(red_over_green: f64, blue_over_green: f64) -> Gains {
        Gains {
            red: 1.0 / red_over_green,
            blue: 1.0 / blue_over_green,
        }
    }

    #[test]
    fn white_balance_gains_on_the_curve_give_its_temperature() {
        assert!((TUNING.colour_temperature(gains_at(0.3031, 0.6573)) - 4559.0).abs() < 1e-6);
        assert!((TUNING.colour_temperature(gains_at(0.4307, 0.3957)) - 2850.0).abs() < 1e-6);
    }

    #[test]
    fn gains_between_two_points_of_the_curve_give_a_temperature_between_them() {
        // The red and blue of 4000 K, linear between 3580 K and 4559 K.
        let share = (4000.0 - 3580.0) / (4559.0 - 3580.0);
        let red = 0.3771 + share * (0.3031 - 0.3771);
        let blue = 0.5176 + share * (0.6573 - 0.5176);
        assert!((TUNING.colour_temperature(gains_at(red, blue)) - 4000.0).abs() < 1e-6);
    }

    #[test]
    fn gains_beyond_the_curve_give_its_nearest_end() {
        assert_eq!(TUNING.colour_temperature(gains_at(0.6, 0.2)), 2850.0);
        assert_eq!(TUNING.colour_temperature(gains_at(0.1, 0.9)), 7600.0);
    }

    #[test]
    fn the_matrix_at_a_calibrated_temperature_is_its_own() {
        assert_eq!(
            TUNING.colour_matrix(4559.0),
            [
                2.15423, -0.98143, -0.17279, -0.38131, 2.14763, -0.76632, -0.10069, -0.54383,
                1.64452
            ]
        );
    }

    #[test]
    fn between_two_calibrated_temperatures_the_matrix_is_interpolated() {
        let quarter = 4559.0 + 0.25 * (5881.0 - 4559.0);
        let low = TUNING.colour_matrices[3].matrix;
        let high = TUNING.colour_matrices[4].matrix;
        let matrix = TUNING.colour_matrix(quarter);
        for i in 0..9 {
            assert!((matrix[i] - (0.75 * low[i] + 0.25 * high[i])).abs() < 1e-12);
        }
    }

    #[test]
    fn beyond_the_calibrated_temperatures_the_nearest_matrix_holds() {
        assert_eq!(
            TUNING.colour_matrix(2000.0),
            TUNING.colour_matrices[0].matrix
        );
        assert_eq!(
            TUNING.colour_matrix(9000.0),
            TUNING.colour_matrices[5].matrix
        );
    }

    #[test]
    fn the_contrast_curve_keeps_black_and_white_and_never_falls() {
        assert_eq!(TUNING.contrast(0.0), 0.0);
        assert_eq!(TUNING.contrast(65535.0), 65535.0);
        assert_eq!(TUNING.contrast(16384.0), 38445.0);
        // Halfway between the points at 512 and 1024.
        assert_eq!(TUNING.contrast(768.0), (2518.0 + 5033.0) / 2.0);
        let outputs: Vec<f64> = (0..=65535)
            .step_by(7)
            .map(|x| TUNING.contrast(f64::from(x)))
            .collect();
        assert!(outputs.windows(2).all(|pair| pair[0] <= pair[1]));
    }

    #[test]
    fn lens_shading_has_a_vertex_more_than_cells_each_way() {
        let shading = TUNING.lens_shading(4000.0);
        assert_eq!((shading.columns, shading.rows), (33, 33));
        assert!(shading.gains.iter().all(|gains| gains.len() == 33 * 33));
    }

    // The tables are in the order of the frame turned by 180 degrees: the
    // readout's first vertex is the tables' last cell.
    #[test]
    fn lens_shading_brightens_the_corners_and_leaves_the_centre() {
        let shading = TUNING.lens_shading(3000.0);
        let tables = &TUNING.lens_shading;
        let luminance = |cell: usize| (tables.luminance[cell] - 1.0) * 0.8 + 1.0;
        let red_minimum = tables.red[0].table.iter().copied().fold(f64::MAX, f64::min);
        let blue_minimum = tables.blue[0]
            .table
            .iter()
            .copied()
            .fold(f64::MAX, f64::min);
        let [red, green, blue] = &shading.gains;
        let top_left = 0;
        assert!((green[top_left] - luminance(1023)).abs() < 1e-12);
        assert!(
            (red[top_left] - tables.red[0].table[1023] / red_minimum * luminance(1023)).abs()
                < 1e-12
        );
        assert!(
            (blue[top_left] - tables.blue[0].table[1023] / blue_minimum * luminance(1023)).abs()
                < 1e-12
        );
        let bottom_right = 33 * 33 - 1;
        assert!((green[bottom_right] - luminance(0)).abs() < 1e-12);
        let top_right = 32;
        assert!((green[top_right] - luminance(992)).abs() < 1e-12);
        // The centre vertex is the mean of the four cells around it.
        let centre = 16 * 33 + 16;
        let centre_cells = (luminance(15 * 32 + 15)
            + luminance(15 * 32 + 16)
            + luminance(16 * 32 + 15)
            + luminance(16 * 32 + 16))
            / 4.0;
        assert!((green[centre] - centre_cells).abs() < 1e-12);
        assert!(green[centre] < 1.01);
        assert!(green[top_left] > 1.4);
    }

    #[test]
    fn the_colour_tables_are_interpolated_by_temperature_then_brought_to_a_minimum_of_one() {
        let shading = TUNING.lens_shading(4000.0);
        let tables = &TUNING.lens_shading;
        let red_at = |cell: usize| (tables.red[0].table[cell] + tables.red[1].table[cell]) / 2.0;
        let minimum = (0..1024).map(red_at).fold(f64::MAX, f64::min);
        let luminance = (tables.luminance[1023] - 1.0) * 0.8 + 1.0;
        assert!((shading.gains[0][0] - red_at(1023) / minimum * luminance).abs() < 1e-12);
        assert!(shading.gains.iter().flatten().all(|&gain| gain >= 1.0));
    }
}
