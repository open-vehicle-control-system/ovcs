"""Writes a sensor's colour tuning as a Rust module of `v4l2_capture`.

Reads one of Raspberry Pi's libcamera tuning files
(`src/ipa/rpi/pisp/data/<sensor>.json`, BSD-2-Clause, Raspberry Pi Ltd) and
prints the `Tuning` it holds: `rpi.awb`'s colour temperature curve,
`rpi.ccm`'s matrices, `rpi.alsc`'s tables and `rpi.contrast`'s gamma curve,
the values as they are in the file. The third argument is the sensor's
rotation in Raspberry Pi's device tree, 0 or 180: libcamera reads the sensor
out turned by it, so the tables are in that order. Run from
`vision/rust/v4l2_capture`:

    python3 -I libcamera_tuning.py <libcamera>/src/ipa/rpi/pisp/data/imx477.json \
        "libcamera v0.7.1" 180 > src/tuning/imx477.rs && rustfmt src/tuning/imx477.rs
"""

import json
import sys

LICENCE = """Copyright (c) 2019-2020 Raspberry Pi Ltd. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."""


def number(value):
    """A JSON number as a Rust `f64` literal."""
    text = repr(float(value))
    return text if "e" in text or "." in text else text + ".0"


def numbers(values):
    """A Rust array of `f64` literals."""
    return "[" + ", ".join(number(value) for value in values) + "]"


def algorithms(path):
    """The tuning file's algorithms, by name."""
    with open(path) as file:
        tuning = json.load(file)
    return {name: block for entry in tuning["algorithms"] for name, block in entry.items()}


def colour_shading(calibrations):
    """`rpi.alsc`'s colour tables, one per colour temperature."""
    return "".join(
        f"ColourShading {{ kelvin: {number(calibration['ct'])}, "
        f"table: &{numbers(calibration['table'])} }},"
        for calibration in calibrations
    )


def module(path, source, rotation):
    """The Rust module of the tuning file at `path`, from `source`, for a
    sensor whose device tree rotation is `rotation`."""
    blocks = algorithms(path)
    curve = blocks["rpi.awb"]["ct_curve"]
    shading = blocks["rpi.alsc"]
    luminance = shading["luminance_lut"]
    side = int(len(luminance) ** 0.5)
    if side * side != len(luminance):
        sys.exit(f"{path}: a lens shading table of {len(luminance)} cells is not square")
    gamma = blocks["rpi.contrast"]["gamma_curve"]
    doc = "\n".join(("//! " + line).rstrip() for line in LICENCE.splitlines())
    file = path.split("/")[-1]
    return f"""//! The values of Raspberry Pi's tuning of the {file.removesuffix(".json").upper()} for libcamera's
//! PiSP pipeline (`src/ipa/rpi/pisp/data/{file}`, {source}),
//! written by `libcamera_tuning.py`. Its licence:
//!
//! ```text
{doc}
//! ```

use super::{{ColourMatrix, ColourShading, LensShadingTables, Tuning}};

pub const TUNING: Tuning = Tuning {{
    colour_temperature_curve: &[{"".join(numbers(curve[i:i + 3]) + "," for i in range(0, len(curve), 3))}],
    colour_matrices: &[{"".join(f"ColourMatrix {{ kelvin: {number(entry['ct'])}, matrix: {numbers(entry['ccm'])} }}," for entry in blocks["rpi.ccm"]["ccms"])}],
    lens_shading: LensShadingTables {{
        rotated_180: {"true" if rotation == "180" else "false"},
        columns: {side},
        rows: {side},
        luminance: &{numbers(luminance)},
        luminance_strength: {number(shading["luminance_strength"])},
        red: &[{colour_shading(shading["calibrations_Cr"])}],
        blue: &[{colour_shading(shading["calibrations_Cb"])}],
    }},
    contrast_curve: &[{"".join(f"[{int(gamma[i])}, {int(gamma[i + 1])}]," for i in range(0, len(gamma), 2))}],
}};
"""


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[3] not in ("0", "180"):
        sys.exit(__doc__)
    print(module(sys.argv[1], sys.argv[2], sys.argv[3]), end="")
