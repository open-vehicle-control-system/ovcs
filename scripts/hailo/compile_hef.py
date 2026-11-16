"""Compiles a segmentation ONNX into a Hailo-8 HEF with Hailo's Dataflow Compiler.

It parses the model, quantises it on calibration images, then compiles it, as
the model script (`.alls`) says. Each calibration image is cropped to the band
a segmentation pipeline hands the model by default, its full width and the
model's aspect ratio at its bottom, then resized to the model's input.

usage: python compile_hef.py <model.onnx> <name> <model.alls> <calibration dir> <out.hef>

The calibration directory holds JPEG frames of the camera the model will run on.
"""

import sys
import time
from pathlib import Path

import numpy as np
from hailo_sdk_client import ClientRunner
from PIL import Image


def band(path, height, width):
    """The bottom band of the image at `path`, of the model's aspect ratio, at its size."""
    image = Image.open(path).convert("RGB")
    image_width, image_height = image.size
    band_height = min(round(image_width * height / width), image_height)
    cropped = image.crop((0, image_height - band_height, image_width, image_height))
    return np.asarray(cropped.resize((width, height), Image.BILINEAR))


def compile_hef(onnx_path, name, alls_path, calibration_dir, out):
    runner = ClientRunner(hw_arch="hailo8")
    runner.translate_onnx_model(onnx_path, name)
    _, height, width, _ = runner.get_hn_model().get_input_layers()[0].input_shape
    frames = sorted(Path(calibration_dir).glob("*.jpg"))
    if not frames:
        sys.exit(f"no .jpg frames in {calibration_dir}")
    calibration = np.stack([band(frame, height, width) for frame in frames]).astype(np.float32)
    print(f"input {height}x{width}, {len(frames)} calibration frames", flush=True)

    runner.load_model_script(Path(alls_path).read_text())
    started = time.monotonic()
    runner.optimize(calibration)
    print(f"optimised in {time.monotonic() - started:.0f} s", flush=True)
    started = time.monotonic()
    Path(out).write_bytes(runner.compile())
    print(f"compiled in {time.monotonic() - started:.0f} s: {out}", flush=True)


def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    compile_hef(*sys.argv[1:6])


if __name__ == "__main__":
    main()
